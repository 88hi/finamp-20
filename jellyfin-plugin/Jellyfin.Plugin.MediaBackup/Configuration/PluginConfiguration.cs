using MediaBrowser.Model.Plugins;

namespace Jellyfin.Plugin.MediaBackup.Configuration;

/// <summary>
/// Plugin configuration for Media Backup.
/// </summary>
public class PluginConfiguration : BasePluginConfiguration
{
    /// <summary>
    /// Gets or sets the root directory where uploaded photos and videos are stored.
    /// </summary>
    public string BackupRootPath { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets a value indicating whether to keep the selected folder name directly under BackupRootPath.
    /// When true: BackupRootPath/SelectedFolder/FileName.
    /// When false: BackupRootPath/FileName.
    /// </summary>
    public bool PreserveFolderName { get; set; } = true;

    /// <summary>
    /// Gets or sets a value indicating whether to trigger a Jellyfin library scan after uploads finish.
    /// </summary>
    public bool AutoScanLibrary { get; set; } = true;

    /// <summary>
    /// Gets or sets the maximum allowed file size in megabytes.
    /// </summary>
    public long MaxFileSizeMB { get; set; } = 4096;

    /// <summary>
    /// Gets or sets comma-separated allowed file extensions (lowercase, with leading dot).
    /// </summary>
    public string AllowedExtensions { get; set; } =
        ".jpg,.jpeg,.png,.gif,.webp,.heic,.heif,.dng,.bmp,.tif,.tiff,.mp4,.mov,.mkv,.avi,.webm,.3gp,.m4v,.mts,.m2ts";
}
