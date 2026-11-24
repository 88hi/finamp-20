import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _backupLogger = Logger("MediaBackupService");

const _mediaBackupChannel = MethodChannel("com.unicornsonlsd.finamp/media_backup");

const int _directUploadThresholdBytes = 8 * 1024 * 1024; // 8 MB
const int _chunkSizeBytes = 4 * 1024 * 1024; // 4 MB

final mediaBackupServiceProvider = ChangeNotifierProvider<MediaBackupService>((ref) {
  return GetIt.instance<MediaBackupService>();
});

class MediaBackupFolder {
  const MediaBackupFolder({
    required this.bucketId,
    required this.name,
    required this.photoCount,
    required this.videoCount,
    required this.totalBytes,
  });

  final String bucketId;
  final String name;
  final int photoCount;
  final int videoCount;
  final int totalBytes;

  int get totalCount => photoCount + videoCount;

  factory MediaBackupFolder.fromMap(Map<dynamic, dynamic> map) {
    return MediaBackupFolder(
      bucketId: (map['bucketId'] as String?) ?? '',
      name: (map['name'] as String?) ?? 'Unknown',
      photoCount: (map['photoCount'] as num?)?.toInt() ?? 0,
      videoCount: (map['videoCount'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class MediaBackupItem {
  const MediaBackupItem({
    required this.id,
    required this.contentUri,
    required this.bucketId,
    required this.bucketName,
    required this.fileName,
    required this.size,
    required this.dateModifiedMs,
    required this.mimeType,
    required this.isVideo,
  });

  final String id;
  final String contentUri;
  final String bucketId;
  final String bucketName;
  final String fileName;
  final int size;
  final int dateModifiedMs;
  final String mimeType;
  final bool isVideo;

  String get localCacheKey => '${id}_$size';

  factory MediaBackupItem.fromMap(Map<dynamic, dynamic> map) {
    return MediaBackupItem(
      id: (map['id'] as String?) ?? '',
      contentUri: (map['contentUri'] as String?) ?? '',
      bucketId: (map['bucketId'] as String?) ?? '',
      bucketName: (map['bucketName'] as String?) ?? 'Unknown',
      fileName: (map['fileName'] as String?) ?? '',
      size: (map['size'] as num?)?.toInt() ?? 0,
      dateModifiedMs: (map['dateModifiedMs'] as num?)?.toInt() ?? 0,
      mimeType: (map['mimeType'] as String?) ?? 'application/octet-stream',
      isVideo: (map['isVideo'] as bool?) ?? false,
    );
  }
}

class MediaBackupFailedItem {
  const MediaBackupFailedItem({
    required this.item,
    required this.error,
  });

  final MediaBackupItem item;
  final String error;
}

class MediaBackupServerStatus {
  const MediaBackupServerStatus({
    required this.installed,
    required this.configured,
    this.version = '',
    this.preserveFolderName = true,
    this.maxFileSizeMB = 4096,
    this.errorMessage,
  });

  final bool installed;
  final bool configured;
  final String version;
  final bool preserveFolderName;
  final int maxFileSizeMB;
  final String? errorMessage;
}

class MediaBackupServerStats {
  const MediaBackupServerStats({
    this.totalFiles = 0,
    this.photoCount = 0,
    this.videoCount = 0,
    this.totalBytes = 0,
  });

  final int totalFiles;
  final int photoCount;
  final int videoCount;
  final int totalBytes;

  factory MediaBackupServerStats.fromJson(Map<String, dynamic> json) {
    return MediaBackupServerStats(
      totalFiles: (json['TotalFiles'] as num? ?? json['totalFiles'] as num?)?.toInt() ?? 0,
      photoCount: (json['PhotoCount'] as num? ?? json['photoCount'] as num?)?.toInt() ?? 0,
      videoCount: (json['VideoCount'] as num? ?? json['videoCount'] as num?)?.toInt() ?? 0,
      totalBytes: (json['TotalBytes'] as num? ?? json['totalBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

class MediaBackupService extends ChangeNotifier {
  static const _prefSelectedBuckets = 'media_backup_selected_buckets';
  static const _prefIncludePhotos = 'media_backup_include_photos';
  static const _prefIncludeVideos = 'media_backup_include_videos';
  static const _prefWifiOnly = 'media_backup_wifi_only';
  static const _prefChargingOnly = 'media_backup_charging_only';
  static const _prefUploadedKeys = 'media_backup_uploaded_keys';

  FinampUserHelper get _userHelper => GetIt.instance<FinampUserHelper>();

  bool _initialized = false;
  bool _hasPermission = false;
  bool _isLoadingFolders = false;
  bool _isCheckingServer = false;
  bool _isBackingUp = false;
  bool _cancelRequested = false;

  bool _includePhotos = true;
  bool _includeVideos = true;
  bool _wifiOnly = true;
  bool _chargingOnly = false;

  Set<String> _selectedBucketIds = {};
  Set<String> _uploadedLocalKeys = {};
  List<MediaBackupFolder> _folders = const [];

  MediaBackupServerStatus? _serverStatus;
  MediaBackupServerStats? _serverStats;

  int _totalToProcess = 0;
  int _uploadedCount = 0;
  int _skippedCount = 0;
  int _bytesUploadedThisRun = 0;
  double _currentFileProgress = 0.0;
  double _uploadSpeedBytesPerSec = 0.0;
  String? _currentFileName;
  String? _statusMessage;
  List<MediaBackupFailedItem> _failedItems = const [];

  bool get isSupported => Platform.isAndroid;
  bool get hasPermission => _hasPermission;
  bool get isLoadingFolders => _isLoadingFolders;
  bool get isCheckingServer => _isCheckingServer;
  bool get isBackingUp => _isBackingUp;
  bool get includePhotos => _includePhotos;
  bool get includeVideos => _includeVideos;
  bool get wifiOnly => _wifiOnly;
  bool get chargingOnly => _chargingOnly;
  Set<String> get selectedBucketIds => Set.unmodifiable(_selectedBucketIds);
  List<MediaBackupFolder> get folders => _folders;
  MediaBackupServerStatus? get serverStatus => _serverStatus;
  MediaBackupServerStats? get serverStats => _serverStats;

  int get totalToProcess => _totalToProcess;
  int get uploadedCount => _uploadedCount;
  int get skippedCount => _skippedCount;
  int get processedCount => _uploadedCount + _skippedCount + _failedItems.length;
  int get bytesUploadedThisRun => _bytesUploadedThisRun;
  double get currentFileProgress => _currentFileProgress;
  double get uploadSpeedBytesPerSec => _uploadSpeedBytesPerSec;
  String? get currentFileName => _currentFileName;
  String? get statusMessage => _statusMessage;
  List<MediaBackupFailedItem> get failedItems => _failedItems;

  double get overallProgress {
    if (_totalToProcess <= 0) return 0.0;
    return ((processedCount + _currentFileProgress) / _totalToProcess).clamp(0.0, 1.0);
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await SharedPreferences.getInstance();
    _selectedBucketIds = (prefs.getStringList(_prefSelectedBuckets) ?? const []).toSet();
    _includePhotos = prefs.getBool(_prefIncludePhotos) ?? true;
    _includeVideos = prefs.getBool(_prefIncludeVideos) ?? true;
    _wifiOnly = prefs.getBool(_prefWifiOnly) ?? true;
    _chargingOnly = prefs.getBool(_prefChargingOnly) ?? false;
    _uploadedLocalKeys = (prefs.getStringList(_prefUploadedKeys) ?? const []).toSet();
    notifyListeners();
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefSelectedBuckets, _selectedBucketIds.toList());
    await prefs.setBool(_prefIncludePhotos, _includePhotos);
    await prefs.setBool(_prefIncludeVideos, _includeVideos);
    await prefs.setBool(_prefWifiOnly, _wifiOnly);
    await prefs.setBool(_prefChargingOnly, _chargingOnly);
  }

  Future<void> _saveUploadedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefUploadedKeys, _uploadedLocalKeys.toList());
  }

  Future<void> clearLocalUploadCache() async {
    _uploadedLocalKeys.clear();
    await _saveUploadedKeys();
    notifyListeners();
  }

  Future<void> setIncludePhotos(bool value) async {
    _includePhotos = value;
    await _savePrefs();
    notifyListeners();
    if (_hasPermission) {
      await loadFolders();
    }
  }

  Future<void> setIncludeVideos(bool value) async {
    _includeVideos = value;
    await _savePrefs();
    notifyListeners();
    if (_hasPermission) {
      await loadFolders();
    }
  }

  Future<void> setWifiOnly(bool value) async {
    _wifiOnly = value;
    await _savePrefs();
    notifyListeners();
  }

  Future<void> setChargingOnly(bool value) async {
    _chargingOnly = value;
    await _savePrefs();
    notifyListeners();
  }

  Future<void> toggleBucket(String bucketId, bool selected) async {
    if (selected) {
      _selectedBucketIds.add(bucketId);
    } else {
      _selectedBucketIds.remove(bucketId);
    }
    await _savePrefs();
    notifyListeners();
  }

  Future<bool> requestPermissionsAndLoadFolders() async {
    await initialize();
    if (!Platform.isAndroid) return false;

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    bool granted = false;
    if (sdkInt >= 33) {
      final statuses = await [Permission.photos, Permission.videos].request();
      granted = (statuses[Permission.photos]?.isGranted ?? false) ||
          (statuses[Permission.photos]?.isLimited ?? false) ||
          (statuses[Permission.videos]?.isGranted ?? false) ||
          (statuses[Permission.videos]?.isLimited ?? false);
    } else {
      final status = await Permission.storage.request();
      granted = status.isGranted;
    }

    _hasPermission = granted;
    notifyListeners();

    if (granted) {
      await loadFolders();
    }
    return granted;
  }

  Future<void> loadFolders() async {
    if (!Platform.isAndroid) return;
    _isLoadingFolders = true;
    notifyListeners();

    try {
      final raw = await _mediaBackupChannel.invokeMethod<List<dynamic>>(
        'listMediaFolders',
        {
          'includePhotos': _includePhotos,
          'includeVideos': _includeVideos,
        },
      );
      _folders = (raw ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map(MediaBackupFolder.fromMap)
          .toList();

      // Default select Camera folder if user hasn't picked anything yet.
      if (_selectedBucketIds.isEmpty && _folders.isNotEmpty) {
        final camera = _folders.where((f) => f.name.toLowerCase() == 'camera').firstOrNull;
        if (camera != null) {
          _selectedBucketIds.add(camera.bucketId);
          await _savePrefs();
        }
      }
    } catch (e, stack) {
      _backupLogger.warning("Failed to list media folders: $e", e, stack);
    } finally {
      _isLoadingFolders = false;
      notifyListeners();
    }
  }

  Future<void> checkServerStatus() async {
    await initialize();
    if (FinampSettingsHelper.finampSettings.isOffline || _userHelper.currentUser == null) {
      _serverStatus = const MediaBackupServerStatus(
        installed: false,
        configured: false,
        errorMessage: "Offline or not logged in",
      );
      notifyListeners();
      return;
    }

    _isCheckingServer = true;
    notifyListeners();

    final client = http.Client();
    try {
      final baseUrl = _normalizedBaseUrl;
      final headers = _authHeaders;

      final statusResp = await client
          .get(Uri.parse('$baseUrl/MediaBackup/Status'), headers: headers)
          .timeout(const Duration(seconds: 10));

      if (statusResp.statusCode == 200) {
        final data = jsonDecode(statusResp.body) as Map<String, dynamic>;
        _serverStatus = MediaBackupServerStatus(
          installed: (data['Installed'] as bool? ?? data['installed'] as bool?) ?? true,
          configured: (data['Configured'] as bool? ?? data['configured'] as bool?) ?? false,
          version: (data['Version'] as String? ?? data['version'] as String?) ?? '',
          preserveFolderName:
              (data['PreserveFolderName'] as bool? ?? data['preserveFolderName'] as bool?) ?? true,
          maxFileSizeMB:
              (data['MaxFileSizeMB'] as num? ?? data['maxFileSizeMB'] as num?)?.toInt() ?? 4096,
        );

        // Also fetch aggregate stats
        try {
          final statsResp = await client
              .get(Uri.parse('$baseUrl/MediaBackup/Stats'), headers: headers)
              .timeout(const Duration(seconds: 15));
          if (statsResp.statusCode == 200) {
            _serverStats = MediaBackupServerStats.fromJson(
              jsonDecode(statsResp.body) as Map<String, dynamic>,
            );
          }
        } catch (_) {}
      } else if (statusResp.statusCode == 404) {
        _serverStatus = const MediaBackupServerStatus(
          installed: false,
          configured: false,
          errorMessage: "404: Jellyfin Media Backup plugin not installed",
        );
      } else {
        _serverStatus = MediaBackupServerStatus(
          installed: false,
          configured: false,
          errorMessage: "HTTP ${statusResp.statusCode}",
        );
      }
    } catch (e) {
      _serverStatus = MediaBackupServerStatus(
        installed: false,
        configured: false,
        errorMessage: e.toString(),
      );
    } finally {
      client.close();
      _isCheckingServer = false;
      notifyListeners();
    }
  }

  String get _normalizedBaseUrl {
    final raw = _userHelper.currentUser!.baseURL.trim();
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  Map<String, String> get _authHeaders => Map<String, String>.from(_userHelper.authorizationHeaders);

  void cancelBackup() {
    if (_isBackingUp) {
      _cancelRequested = true;
      notifyListeners();
    }
  }

  Future<String?> startBackup({List<MediaBackupItem>? retryItems}) async {
    if (_isBackingUp) return null;
    await initialize();

    if (FinampSettingsHelper.finampSettings.isOffline || _userHelper.currentUser == null) {
      return "Offline or not logged in";
    }

    // Check Wi-Fi constraint
    if (_wifiOnly) {
      final conn = await Connectivity().checkConnectivity();
      final hasWifiOrEthernet =
          conn.contains(ConnectivityResult.wifi) || conn.contains(ConnectivityResult.ethernet);
      if (!hasWifiOrEthernet) {
        return "WIFI_REQUIRED";
      }
    }

    // Check Charging constraint
    if (_chargingOnly) {
      final state = await Battery().batteryState;
      if (state != BatteryState.charging && state != BatteryState.full) {
        return "CHARGING_REQUIRED";
      }
    }

    await checkServerStatus();
    if (_serverStatus == null || !_serverStatus!.installed) {
      return "PLUGIN_NOT_INSTALLED";
    }
    if (!_serverStatus!.configured) {
      return "PLUGIN_NOT_CONFIGURED";
    }

    if (retryItems == null && _selectedBucketIds.isEmpty) {
      return "NO_FOLDERS_SELECTED";
    }

    _isBackingUp = true;
    _cancelRequested = false;
    _totalToProcess = 0;
    _uploadedCount = 0;
    _skippedCount = 0;
    _bytesUploadedThisRun = 0;
    _currentFileProgress = 0.0;
    _uploadSpeedBytesPerSec = 0.0;
    _currentFileName = null;
    _failedItems = const [];
    _statusMessage = null;
    notifyListeners();

    final client = http.Client();
    final runStopwatch = Stopwatch()..start();

    try {
      List<MediaBackupItem> items;
      if (retryItems != null) {
        items = retryItems;
      } else {
        final rawItems = await _mediaBackupChannel.invokeMethod<List<dynamic>>(
          'listMediaItems',
          {
            'bucketIds': _selectedBucketIds.toList(),
            'includePhotos': _includePhotos,
            'includeVideos': _includeVideos,
          },
        );
        items = (rawItems ?? const [])
            .whereType<Map<dynamic, dynamic>>()
            .map(MediaBackupItem.fromMap)
            .toList();
      }

      _totalToProcess = items.length;
      notifyListeners();

      if (items.isEmpty) {
        return null;
      }

      // Group items by folderName so we can batch-check existence on the server.
      final byFolder = <String, List<MediaBackupItem>>{};
      final pendingToCheck = <MediaBackupItem>[];

      for (final item in items) {
        if (retryItems == null && _uploadedLocalKeys.contains(item.localCacheKey)) {
          _skippedCount++;
        } else {
          pendingToCheck.add(item);
          byFolder.putIfAbsent(item.bucketName, () => []).add(item);
        }
      }
      notifyListeners();

      // Server-side deduplication in batches of 100 per folder.
      final toUpload = <MediaBackupItem>[];
      for (final entry in byFolder.entries) {
        if (_cancelRequested) break;
        final folderName = entry.key;
        final folderItems = entry.value;

        for (int i = 0; i < folderItems.length; i += 100) {
          if (_cancelRequested) break;
          final batch = folderItems.sublist(i, (i + 100).clamp(0, folderItems.length));
          final existingNames = await _checkExistsOnServer(client, folderName, batch);
          for (final item in batch) {
            if (existingNames.contains(item.fileName)) {
              _skippedCount++;
              _uploadedLocalKeys.add(item.localCacheKey);
            } else {
              toUpload.add(item);
            }
          }
          notifyListeners();
        }
      }

      await _saveUploadedKeys();

      final failures = <MediaBackupFailedItem>[];
      for (final item in toUpload) {
        if (_cancelRequested) break;

        // Re-check Wi-Fi mid-run if user switched off Wi-Fi.
        if (_wifiOnly) {
          final conn = await Connectivity().checkConnectivity();
          if (!conn.contains(ConnectivityResult.wifi) &&
              !conn.contains(ConnectivityResult.ethernet)) {
            _statusMessage = "WIFI_REQUIRED";
            break;
          }
        }

        _currentFileName = item.fileName;
        _currentFileProgress = 0.0;
        notifyListeners();

        try {
          if (item.size <= _directUploadThresholdBytes) {
            await _uploadDirect(client, item);
            _bytesUploadedThisRun += item.size;
          } else {
            await _uploadChunked(client, item, onChunkUploaded: (chunkLen, fileUploaded) {
              _bytesUploadedThisRun += chunkLen;
              _currentFileProgress = item.size > 0 ? (fileUploaded / item.size).clamp(0.0, 1.0) : 0.0;
              final secs = runStopwatch.elapsedMilliseconds / 1000.0;
              if (secs > 0.2) {
                _uploadSpeedBytesPerSec = _bytesUploadedThisRun / secs;
              }
              notifyListeners();
            });
          }

          _uploadedCount++;
          _currentFileProgress = 0.0;
          final secs = runStopwatch.elapsedMilliseconds / 1000.0;
          if (secs > 0.2) {
            _uploadSpeedBytesPerSec = _bytesUploadedThisRun / secs;
          }
          _uploadedLocalKeys.add(item.localCacheKey);
          await _saveUploadedKeys();
          notifyListeners();
        } catch (e) {
          _backupLogger.warning("Failed to upload ${item.fileName}: $e");
          failures.add(MediaBackupFailedItem(item: item, error: e.toString()));
          _failedItems = List.unmodifiable(failures);
          notifyListeners();
        }
      }

      _failedItems = List.unmodifiable(failures);
      await checkServerStatus();
      return _statusMessage;
    } finally {
      client.close();
      _isBackingUp = false;
      _currentFileName = null;
      _currentFileProgress = 0.0;
      notifyListeners();
    }
  }

  Future<Set<String>> _checkExistsOnServer(
    http.Client client,
    String folderName,
    List<MediaBackupItem> batch,
  ) async {
    try {
      final uri = Uri.parse('$_normalizedBaseUrl/MediaBackup/CheckExists');
      final headers = {
        ..._authHeaders,
        'Content-Type': 'application/json',
      };
      final body = jsonEncode({
        'FolderName': folderName,
        'Files': batch
            .map((e) => {
                  'FileName': e.fileName,
                  'Size': e.size,
                })
            .toList(),
      });
      final resp = await client.post(uri, headers: headers, body: body).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final raw = (data['ExistingFileNames'] ?? data['existingFileNames']) as List<dynamic>?;
        return raw?.whereType<String>().toSet() ?? const {};
      }
    } catch (e) {
      _backupLogger.fine("CheckExists failed (will proceed to upload): $e");
    }
    return const {};
  }

  Future<void> _uploadDirect(http.Client client, MediaBackupItem item) async {
    final bytes = await _mediaBackupChannel.invokeMethod<Uint8List>(
      'readFileChunk',
      {
        'contentUri': item.contentUri,
        'offset': 0,
        'length': item.size,
      },
    );
    if (bytes == null) {
      throw Exception("Unable to read file bytes");
    }

    final sha256 = await _mediaBackupChannel.invokeMethod<String>(
      'computeSha256',
      {'contentUri': item.contentUri},
    );

    final uri = Uri.parse('$_normalizedBaseUrl/MediaBackup/Upload').replace(
      queryParameters: {
        'folderName': item.bucketName,
        'fileName': item.fileName,
        if (item.dateModifiedMs > 0) 'lastModifiedMs': item.dateModifiedMs.toString(),
        if (sha256 != null && sha256.isNotEmpty) 'sha256': sha256,
      },
    );

    final headers = {
      ..._authHeaders,
      'Content-Type': 'application/octet-stream',
    };

    final resp = await client.post(uri, headers: headers, body: bytes).timeout(const Duration(minutes: 2));
    if (resp.statusCode != 200) {
      throw Exception("HTTP ${resp.statusCode}: ${resp.body}");
    }
  }

  Future<void> _uploadChunked(
    http.Client client,
    MediaBackupItem item, {
    required void Function(int chunkLen, int totalUploadedForFile) onChunkUploaded,
  }) async {
    final sha256 = await _mediaBackupChannel.invokeMethod<String>(
      'computeSha256',
      {'contentUri': item.contentUri},
    );

    // 1. Init / Resume session
    final initUri = Uri.parse('$_normalizedBaseUrl/MediaBackup/Upload/Init');
    final initResp = await client
        .post(
          initUri,
          headers: {
            ..._authHeaders,
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'FolderName': item.bucketName,
            'FileName': item.fileName,
            'TotalSize': item.size,
            if (sha256 != null && sha256.isNotEmpty) 'Sha256': sha256,
            if (item.dateModifiedMs > 0) 'LastModifiedMs': item.dateModifiedMs,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (initResp.statusCode != 200) {
      throw Exception("Init failed (${initResp.statusCode}): ${initResp.body}");
    }

    final initData = jsonDecode(initResp.body) as Map<String, dynamic>;
    final uploadId = (initData['UploadId'] ?? initData['uploadId']) as String;
    int offset = (initData['UploadedBytes'] as num? ?? initData['uploadedBytes'] as num?)?.toInt() ?? 0;

    // 2. Upload chunks sequentially from offset (supports resuming!)
    while (offset < item.size) {
      if (_cancelRequested) {
        throw Exception("Cancelled by user");
      }

      final remaining = item.size - offset;
      final toRead = remaining < _chunkSizeBytes ? remaining : _chunkSizeBytes;
      final chunk = await _mediaBackupChannel.invokeMethod<Uint8List>(
        'readFileChunk',
        {
          'contentUri': item.contentUri,
          'offset': offset,
          'length': toRead,
        },
      );
      if (chunk == null || chunk.isEmpty) {
        throw Exception("Unexpected EOF reading chunk at offset $offset");
      }

      final chunkUri = Uri.parse('$_normalizedBaseUrl/MediaBackup/Upload/Chunk/$uploadId').replace(
        queryParameters: {'offset': offset.toString()},
      );

      final chunkResp = await client
          .put(
            chunkUri,
            headers: {
              ..._authHeaders,
              'Content-Type': 'application/octet-stream',
            },
            body: chunk,
          )
          .timeout(const Duration(minutes: 2));

      if (chunkResp.statusCode != 200) {
        throw Exception("Chunk failed (${chunkResp.statusCode}): ${chunkResp.body}");
      }

      offset += chunk.length;
      onChunkUploaded(chunk.length, offset);
    }

    // 3. Complete session
    final completeUri = Uri.parse('$_normalizedBaseUrl/MediaBackup/Upload/Complete/$uploadId');
    final completeResp = await client
        .post(completeUri, headers: _authHeaders)
        .timeout(const Duration(minutes: 2));

    if (completeResp.statusCode != 200) {
      throw Exception("Complete failed (${completeResp.statusCode}): ${completeResp.body}");
    }
  }
}
