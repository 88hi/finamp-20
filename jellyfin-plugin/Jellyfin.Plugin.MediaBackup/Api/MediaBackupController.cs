using System.Collections.Concurrent;
using System.Net.Mime;
using System.Security.Cryptography;
using Jellyfin.Plugin.MediaBackup.Configuration;
using MediaBrowser.Controller.Library;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.MediaBackup.Api;

[ApiController]
[Route("MediaBackup")]
[Authorize]
public class MediaBackupController : ControllerBase
{
    private static readonly ConcurrentDictionary<string, ChunkSession> ActiveSessions = new();
    private static readonly object ScanTimerLock = new();
    private static Timer? _debouncedScanTimer;

    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".mov", ".mkv", ".avi", ".webm", ".3gp", ".m4v", ".mts", ".m2ts",
    };

    private readonly ILibraryManager _libraryManager;
    private readonly ILogger<MediaBackupController> _logger;

    public MediaBackupController(
        ILibraryManager libraryManager,
        ILogger<MediaBackupController> logger)
    {
        _libraryManager = libraryManager;
        _logger = logger;
    }

    private static PluginConfiguration Config =>
        Plugin.Instance?.Configuration ?? new PluginConfiguration();

    /// <summary>
    /// Returns plugin installation and configuration status.
    /// </summary>
    [HttpGet("Status")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public ActionResult<BackupStatusResponse> GetStatus()
    {
        var cfg = Config;
        var rootConfigured = !string.IsNullOrWhiteSpace(cfg.BackupRootPath);
        return Ok(new BackupStatusResponse
        {
            Installed = true,
            Version = Plugin.Instance?.Version.ToString() ?? "1.0.0.0",
            Configured = rootConfigured,
            PreserveFolderName = cfg.PreserveFolderName,
            MaxFileSizeMB = cfg.MaxFileSizeMB,
            AllowedExtensions = ParseAllowedExtensions(cfg),
        });
    }

    /// <summary>
    /// Returns aggregate backup statistics for the configured backup root.
    /// </summary>
    [HttpGet("Stats")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public ActionResult<BackupStatsResponse> GetStats()
    {
        var cfg = Config;
        if (string.IsNullOrWhiteSpace(cfg.BackupRootPath) || !Directory.Exists(cfg.BackupRootPath))
        {
            return Ok(new BackupStatsResponse());
        }

        int totalFiles = 0;
        int photoCount = 0;
        int videoCount = 0;
        long totalBytes = 0;

        try
        {
            var allowed = new HashSet<string>(ParseAllowedExtensions(cfg), StringComparer.OrdinalIgnoreCase);
            foreach (var path in Directory.EnumerateFiles(cfg.BackupRootPath, "*", SearchOption.AllDirectories))
            {
                var fileName = Path.GetFileName(path);
                if (fileName.StartsWith('.'))
                {
                    continue;
                }

                var ext = Path.GetExtension(fileName);
                if (allowed.Count > 0 && !allowed.Contains(ext))
                {
                    continue;
                }

                try
                {
                    var info = new FileInfo(path);
                    totalFiles++;
                    totalBytes += info.Length;
                    if (VideoExtensions.Contains(ext))
                    {
                        videoCount++;
                    }
                    else
                    {
                        photoCount++;
                    }
                }
                catch
                {
                    // Ignore transient inaccessible files.
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to compute MediaBackup stats");
        }

        return Ok(new BackupStatsResponse
        {
            TotalFiles = totalFiles,
            PhotoCount = photoCount,
            VideoCount = videoCount,
            TotalBytes = totalBytes,
        });
    }

    /// <summary>
    /// Checks which files already exist on the server to enable fast deduplication.
    /// </summary>
    [HttpPost("CheckExists")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public ActionResult<CheckExistsResponse> CheckExists([FromBody] CheckExistsRequest request)
    {
        if (!TryResolveTargetDirectory(request.FolderName, out var targetDir, out var error))
        {
            return BadRequest(new { error });
        }

        var existing = new List<string>();
        if (Directory.Exists(targetDir))
        {
            foreach (var item in request.Files)
            {
                var safeName = SanitizeFileName(item.FileName);
                if (string.IsNullOrEmpty(safeName))
                {
                    continue;
                }

                var fullPath = Path.Combine(targetDir, safeName);
                if (System.IO.File.Exists(fullPath))
                {
                    try
                    {
                        var info = new FileInfo(fullPath);
                        if (item.Size <= 0 || info.Length == item.Size)
                        {
                            existing.Add(item.FileName);
                        }
                    }
                    catch
                    {
                        // Ignore.
                    }
                }
            }
        }

        return Ok(new CheckExistsResponse { ExistingFileNames = existing });
    }

    /// <summary>
    /// Direct streaming upload endpoint for single files (ideal for photos and small videos).
    /// </summary>
    [HttpPost("Upload")]
    [RequestSizeLimit(4L * 1024 * 1024 * 1024)]
    [DisableRequestSizeLimit]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<UploadCompleteResponse>> UploadDirect(
        [FromQuery] string? folderName,
        [FromQuery] string fileName,
        [FromQuery] long? lastModifiedMs,
        [FromQuery] string? sha256,
        CancellationToken cancellationToken)
    {
        if (!ValidateAndPrepareDestination(folderName, fileName, Request.ContentLength, out var targetDir, out var safeFileName, out var destPath, out var error))
        {
            return BadRequest(new { error });
        }

        Directory.CreateDirectory(targetDir);
        var tempPath = Path.Combine(targetDir, $".{safeFileName}.{Guid.NewGuid():N}.part");
        var maxBytes = Config.MaxFileSizeMB * 1024L * 1024L;

        try
        {
            long written = 0;
            string computedHash;

            using (var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            await using (var fs = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 65536, useAsync: true))
            {
                var buffer = new byte[65536];
                int read;
                while ((read = await Request.Body.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken).ConfigureAwait(false)) > 0)
                {
                    written += read;
                    if (written > maxBytes)
                    {
                        throw new InvalidOperationException($"File exceeds configured max size ({Config.MaxFileSizeMB} MB).");
                    }

                    await fs.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                    hasher.AppendData(buffer, 0, read);
                }

                computedHash = Convert.ToHexString(hasher.GetHashAndReset()).ToLowerInvariant();
            }

            if (!string.IsNullOrWhiteSpace(sha256) &&
                !string.Equals(computedHash, sha256.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                TryDeleteFile(tempPath);
                return BadRequest(new { error = "SHA-256 checksum mismatch." });
            }

            FinalizeUploadedFile(tempPath, destPath, lastModifiedMs);
            ScheduleDebouncedLibraryScan();

            return Ok(new UploadCompleteResponse
            {
                Saved = true,
                FileName = safeFileName,
                Size = written,
                Sha256 = computedHash,
            });
        }
        catch (Exception ex)
        {
            TryDeleteFile(tempPath);
            _logger.LogWarning(ex, "Direct upload failed for {FileName}", fileName);
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// Initializes or resumes a chunked upload session for large videos.
    /// </summary>
    [HttpPost("Upload/Init")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public ActionResult<ChunkInitResponse> InitChunkedUpload([FromBody] ChunkInitRequest request)
    {
        if (!ValidateAndPrepareDestination(request.FolderName, request.FileName, request.TotalSize, out var targetDir, out var safeFileName, out var destPath, out var error))
        {
            return BadRequest(new { error });
        }

        Directory.CreateDirectory(targetDir);

        // Deterministic temp file name allows resuming across retries or restarts.
        var resumeKey = ComputeResumeKey(targetDir, safeFileName, request.TotalSize);
        var tempPath = Path.Combine(targetDir, $".resume_{resumeKey}.part");
        long existingBytes = 0;
        if (System.IO.File.Exists(tempPath))
        {
            try
            {
                var len = new FileInfo(tempPath).Length;
                if (len > 0 && len <= request.TotalSize)
                {
                    existingBytes = len;
                }
                else
                {
                    TryDeleteFile(tempPath);
                }
            }
            catch
            {
                TryDeleteFile(tempPath);
            }
        }

        var session = new ChunkSession
        {
            UploadId = resumeKey,
            TempPath = tempPath,
            DestPath = destPath,
            SafeFileName = safeFileName,
            TotalSize = request.TotalSize,
            ExpectedSha256 = request.Sha256,
            LastModifiedMs = request.LastModifiedMs,
            CreatedUtc = DateTime.UtcNow,
        };

        ActiveSessions[resumeKey] = session;
        CleanupStaleSessions();

        return Ok(new ChunkInitResponse
        {
            UploadId = resumeKey,
            UploadedBytes = existingBytes,
        });
    }

    /// <summary>
    /// Appends a chunk of bytes to an active resumable upload session.
    /// </summary>
    [HttpPut("Upload/Chunk/{uploadId}")]
    [DisableRequestSizeLimit]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<ChunkProgressResponse>> UploadChunk(
        [FromRoute] string uploadId,
        [FromQuery] long offset,
        CancellationToken cancellationToken)
    {
        if (!ActiveSessions.TryGetValue(uploadId, out var session))
        {
            return NotFound(new { error = "Upload session not found or expired." });
        }

        if (offset < 0 || offset > session.TotalSize)
        {
            return BadRequest(new { error = "Invalid chunk offset." });
        }

        try
        {
            await using var fs = new FileStream(session.TempPath, FileMode.OpenOrCreate, FileAccess.Write, FileShare.None, 65536, useAsync: true);
            fs.Seek(offset, SeekOrigin.Begin);

            var buffer = new byte[65536];
            long written = 0;
            int read;
            while ((read = await Request.Body.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken).ConfigureAwait(false)) > 0)
            {
                written += read;
                if (offset + written > session.TotalSize)
                {
                    return BadRequest(new { error = "Chunk exceeds declared totalSize." });
                }

                await fs.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
            }

            await fs.FlushAsync(cancellationToken).ConfigureAwait(false);
            return Ok(new ChunkProgressResponse { UploadedBytes = offset + written });
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Chunk upload failed for {UploadId} at offset {Offset}", uploadId, offset);
            return BadRequest(new { error = ex.Message });
        }
    }

    /// <summary>
    /// Completes a chunked upload session, validates size/checksum, and moves the file to its final path.
    /// </summary>
    [HttpPost("Upload/Complete/{uploadId}")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<UploadCompleteResponse>> CompleteChunkedUpload(
        [FromRoute] string uploadId,
        CancellationToken cancellationToken)
    {
        if (!ActiveSessions.TryRemove(uploadId, out var session))
        {
            return NotFound(new { error = "Upload session not found or expired." });
        }

        if (!System.IO.File.Exists(session.TempPath))
        {
            return BadRequest(new { error = "Temporary upload file is missing." });
        }

        try
        {
            var info = new FileInfo(session.TempPath);
            if (session.TotalSize > 0 && info.Length != session.TotalSize)
            {
                return BadRequest(new { error = $"Incomplete upload: expected {session.TotalSize} bytes, got {info.Length} bytes." });
            }

            string computedHash;
            await using (var fs = new FileStream(session.TempPath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true))
            {
                var hashBytes = await SHA256.HashDataAsync(fs, cancellationToken).ConfigureAwait(false);
                computedHash = Convert.ToHexString(hashBytes).ToLowerInvariant();
            }

            if (!string.IsNullOrWhiteSpace(session.ExpectedSha256) &&
                !string.Equals(computedHash, session.ExpectedSha256.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                TryDeleteFile(session.TempPath);
                return BadRequest(new { error = "SHA-256 checksum mismatch." });
            }

            FinalizeUploadedFile(session.TempPath, session.DestPath, session.LastModifiedMs);
            ScheduleDebouncedLibraryScan();

            return Ok(new UploadCompleteResponse
            {
                Saved = true,
                FileName = session.SafeFileName,
                Size = info.Length,
                Sha256 = computedHash,
            });
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to finalize chunked upload {UploadId}", uploadId);
            return BadRequest(new { error = ex.Message });
        }
    }

    private bool ValidateAndPrepareDestination(
        string? folderName,
        string fileName,
        long? declaredSize,
        out string targetDir,
        out string safeFileName,
        out string destPath,
        out string error)
    {
        safeFileName = string.Empty;
        destPath = string.Empty;

        if (!TryResolveTargetDirectory(folderName, out targetDir, out error))
        {
            return false;
        }

        safeFileName = SanitizeFileName(fileName);
        if (string.IsNullOrEmpty(safeFileName))
        {
            error = "Invalid file name.";
            return false;
        }

        var ext = Path.GetExtension(safeFileName);
        var allowed = ParseAllowedExtensions(Config);
        if (allowed.Length > 0 && !allowed.Contains(ext, StringComparer.OrdinalIgnoreCase))
        {
            error = $"File extension '{ext}' is not allowed.";
            return false;
        }

        var maxBytes = Config.MaxFileSizeMB * 1024L * 1024L;
        if (declaredSize.HasValue && declaredSize.Value > maxBytes)
        {
            error = $"File exceeds configured max size ({Config.MaxFileSizeMB} MB).";
            return false;
        }

        var rootFull = Path.GetFullPath(Config.BackupRootPath.Trim());
        destPath = Path.GetFullPath(Path.Combine(targetDir, safeFileName));
        if (!destPath.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
        {
            error = "Resolved path escapes backup root directory.";
            return false;
        }

        return true;
    }

    private static bool TryResolveTargetDirectory(string? folderName, out string targetDir, out string error)
    {
        targetDir = string.Empty;
        error = string.Empty;

        var cfg = Config;
        if (string.IsNullOrWhiteSpace(cfg.BackupRootPath))
        {
            error = "BackupRootPath is not configured in Jellyfin Dashboard -> Plugins -> Media Backup.";
            return false;
        }

        var rootFull = Path.GetFullPath(cfg.BackupRootPath.Trim());
        if (cfg.PreserveFolderName && !string.IsNullOrWhiteSpace(folderName))
        {
            var safeFolder = SanitizeFileName(folderName);
            if (!string.IsNullOrEmpty(safeFolder))
            {
                var combined = Path.GetFullPath(Path.Combine(rootFull, safeFolder));
                if (!combined.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase))
                {
                    error = "Invalid folderName.";
                    return false;
                }

                targetDir = combined;
                return true;
            }
        }

        targetDir = rootFull;
        return true;
    }

    private static string SanitizeFileName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return string.Empty;
        }

        var trimmed = Path.GetFileName(name.Trim());
        if (trimmed is "." or "..")
        {
            return string.Empty;
        }

        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new char[trimmed.Length];
        for (int i = 0; i < trimmed.Length; i++)
        {
            var ch = trimmed[i];
            cleaned[i] = Array.IndexOf(invalid, ch) >= 0 || ch == '/' || ch == '\\' ? '_' : ch;
        }

        return new string(cleaned).Trim();
    }

    private static string[] ParseAllowedExtensions(PluginConfiguration cfg)
    {
        if (string.IsNullOrWhiteSpace(cfg.AllowedExtensions))
        {
            return [];
        }

        return cfg.AllowedExtensions
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(e => e.StartsWith('.') ? e.ToLowerInvariant() : "." + e.ToLowerInvariant())
            .Distinct()
            .ToArray();
    }

    private static string ComputeResumeKey(string targetDir, string safeFileName, long totalSize)
    {
        var input = $"{targetDir}|{safeFileName}|{totalSize}";
        var bytes = SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(input));
        return Convert.ToHexString(bytes[..12]).ToLowerInvariant();
    }

    private static void FinalizeUploadedFile(string tempPath, string destPath, long? lastModifiedMs)
    {
        if (System.IO.File.Exists(destPath))
        {
            System.IO.File.Delete(destPath);
        }

        System.IO.File.Move(tempPath, destPath);
        if (lastModifiedMs.HasValue && lastModifiedMs.Value > 0)
        {
            try
            {
                var dt = DateTimeOffset.FromUnixTimeMilliseconds(lastModifiedMs.Value).UtcDateTime;
                System.IO.File.SetLastWriteTimeUtc(destPath, dt);
            }
            catch
            {
                // Non-fatal if OS rejects timestamp.
            }
        }
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (System.IO.File.Exists(path))
            {
                System.IO.File.Delete(path);
            }
        }
        catch
        {
            // Ignore cleanup errors.
        }
    }

    private static void CleanupStaleSessions()
    {
        var cutoff = DateTime.UtcNow.AddHours(-12);
        foreach (var kv in ActiveSessions)
        {
            if (kv.Value.CreatedUtc < cutoff)
            {
                ActiveSessions.TryRemove(kv.Key, out _);
            }
        }
    }

    private void ScheduleDebouncedLibraryScan()
    {
        if (!Config.AutoScanLibrary)
        {
            return;
        }

        lock (ScanTimerLock)
        {
            _debouncedScanTimer?.Dispose();
            _debouncedScanTimer = new Timer(_ =>
            {
                try
                {
                    _logger.LogInformation("Triggering Jellyfin library scan after MediaBackup uploads");
                    _ = _libraryManager.ValidateMediaLibrary(new Progress<double>(), CancellationToken.None);
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Failed to trigger Jellyfin library scan");
                }
            }, null, TimeSpan.FromSeconds(15), Timeout.InfiniteTimeSpan);
        }
    }

    private sealed class ChunkSession
    {
        public required string UploadId { get; init; }
        public required string TempPath { get; init; }
        public required string DestPath { get; init; }
        public required string SafeFileName { get; init; }
        public long TotalSize { get; init; }
        public string? ExpectedSha256 { get; init; }
        public long? LastModifiedMs { get; init; }
        public DateTime CreatedUtc { get; init; }
    }
}

public class BackupStatusResponse
{
    public bool Installed { get; set; }
    public string Version { get; set; } = string.Empty;
    public bool Configured { get; set; }
    public bool PreserveFolderName { get; set; }
    public long MaxFileSizeMB { get; set; }
    public string[] AllowedExtensions { get; set; } = [];
}

public class BackupStatsResponse
{
    public int TotalFiles { get; set; }
    public int PhotoCount { get; set; }
    public int VideoCount { get; set; }
    public long TotalBytes { get; set; }
}

public class CheckExistsRequest
{
    public string? FolderName { get; set; }
    public List<CheckFileEntry> Files { get; set; } = [];
}

public class CheckFileEntry
{
    public string FileName { get; set; } = string.Empty;
    public long Size { get; set; }
    public string? Sha256 { get; set; }
}

public class CheckExistsResponse
{
    public List<string> ExistingFileNames { get; set; } = [];
}

public class ChunkInitRequest
{
    public string? FolderName { get; set; }
    public string FileName { get; set; } = string.Empty;
    public long TotalSize { get; set; }
    public string? Sha256 { get; set; }
    public long? LastModifiedMs { get; set; }
}

public class ChunkInitResponse
{
    public string UploadId { get; set; } = string.Empty;
    public long UploadedBytes { get; set; }
}

public class ChunkProgressResponse
{
    public long UploadedBytes { get; set; }
}

public class UploadCompleteResponse
{
    public bool Saved { get; set; }
    public string FileName { get; set; } = string.Empty;
    public long Size { get; set; }
    public string Sha256 { get; set; } = string.Empty;
}
