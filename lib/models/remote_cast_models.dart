import 'package:finamp/models/jellyfin_models.dart';

/// Represents the playback state of a remote Jellyfin session.
class RemotePlayState {
  const RemotePlayState({
    this.positionTicks = 0,
    this.canSeek = false,
    this.isPaused = false,
    this.isMuted = false,
    this.volumeLevel,
    this.repeatMode,
    this.playbackOrder,
    this.playMethod,
  });

  final int positionTicks;
  final bool canSeek;
  final bool isPaused;
  final bool isMuted;
  final int? volumeLevel;
  final String? repeatMode;
  final String? playbackOrder;
  final String? playMethod;

  Duration get position => Duration(microseconds: positionTicks ~/ 10);

  RemotePlayState copyWith({
    int? positionTicks,
    bool? canSeek,
    bool? isPaused,
    bool? isMuted,
    int? volumeLevel,
    String? repeatMode,
    String? playbackOrder,
    String? playMethod,
  }) {
    return RemotePlayState(
      positionTicks: positionTicks ?? this.positionTicks,
      canSeek: canSeek ?? this.canSeek,
      isPaused: isPaused ?? this.isPaused,
      isMuted: isMuted ?? this.isMuted,
      volumeLevel: volumeLevel ?? this.volumeLevel,
      repeatMode: repeatMode ?? this.repeatMode,
      playbackOrder: playbackOrder ?? this.playbackOrder,
      playMethod: playMethod ?? this.playMethod,
    );
  }

  factory RemotePlayState.fromJson(Map<String, dynamic> json) {
    return RemotePlayState(
      positionTicks: (json['PositionTicks'] as num?)?.toInt() ?? 0,
      canSeek: (json['CanSeek'] as bool?) ?? false,
      isPaused: (json['IsPaused'] as bool?) ?? false,
      isMuted: (json['IsMuted'] as bool?) ?? false,
      volumeLevel: (json['VolumeLevel'] as num?)?.toInt(),
      repeatMode: json['RepeatMode'] as String?,
      playbackOrder: json['PlaybackOrder'] as String?,
      playMethod: json['PlayMethod'] as String?,
    );
  }
}

/// Represents a remote Jellyfin client session that can be controlled via Jellyfin's Sessions API.
class RemoteSession {
  const RemoteSession({
    required this.id,
    this.deviceId,
    required this.deviceName,
    required this.client,
    this.userId,
    this.userName,
    this.applicationVersion,
    this.supportsRemoteControl = false,
    this.supportsMediaControl = false,
    this.isActive = false,
    this.playableMediaTypes = const [],
    this.supportedCommands = const [],
    this.nowPlayingItem,
    this.playState,
    this.nowPlayingQueueFullItems = const [],
  });

  final String id;
  final String? deviceId;
  final String deviceName;
  final String client;
  final String? userId;
  final String? userName;
  final String? applicationVersion;
  final bool supportsRemoteControl;
  final bool supportsMediaControl;
  final bool isActive;
  final List<String> playableMediaTypes;
  final List<String> supportedCommands;
  final BaseItemDto? nowPlayingItem;
  final RemotePlayState? playState;
  final List<BaseItemDto> nowPlayingQueueFullItems;

  bool get supportsAudio {
    if (playableMediaTypes.isEmpty) return true;
    return playableMediaTypes.any((t) => t.toLowerCase() == 'audio');
  }

  bool get isControllable => supportsRemoteControl || supportsMediaControl;

  bool get supportsVolume =>
      supportedCommands.contains('SetVolume') ||
      supportedCommands.contains('VolumeUp') ||
      playState?.volumeLevel != null;

  bool get supportsMute =>
      supportedCommands.contains('ToggleMute') ||
      supportedCommands.contains('Mute') ||
      supportedCommands.contains('SetVolume');

  bool get supportsRepeatMode => supportedCommands.contains('SetRepeatMode');

  bool get supportsShuffle =>
      supportedCommands.contains('SetShuffleQueue') ||
      supportedCommands.contains('SetPlaybackOrder');

  String get displayName => deviceName.isNotEmpty ? deviceName : (client.isNotEmpty ? client : id);

  String get clientSummary {
    if (client.isEmpty) return '';
    if (applicationVersion != null && applicationVersion!.isNotEmpty) {
      return '$client ($applicationVersion)';
    }
    return client;
  }

  RemoteSession copyWith({
    String? id,
    String? deviceId,
    String? deviceName,
    String? client,
    String? userId,
    String? userName,
    String? applicationVersion,
    bool? supportsRemoteControl,
    bool? supportsMediaControl,
    bool? isActive,
    List<String>? playableMediaTypes,
    List<String>? supportedCommands,
    BaseItemDto? nowPlayingItem,
    bool clearNowPlayingItem = false,
    RemotePlayState? playState,
    List<BaseItemDto>? nowPlayingQueueFullItems,
  }) {
    return RemoteSession(
      id: id ?? this.id,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      client: client ?? this.client,
      userId: userId ?? this.userId,
      userName: userName ?? this.userName,
      applicationVersion: applicationVersion ?? this.applicationVersion,
      supportsRemoteControl: supportsRemoteControl ?? this.supportsRemoteControl,
      supportsMediaControl: supportsMediaControl ?? this.supportsMediaControl,
      isActive: isActive ?? this.isActive,
      playableMediaTypes: playableMediaTypes ?? this.playableMediaTypes,
      supportedCommands: supportedCommands ?? this.supportedCommands,
      nowPlayingItem: clearNowPlayingItem ? null : (nowPlayingItem ?? this.nowPlayingItem),
      playState: playState ?? this.playState,
      nowPlayingQueueFullItems: nowPlayingQueueFullItems ?? this.nowPlayingQueueFullItems,
    );
  }

  static RemoteSession? tryFromJson(Map<String, dynamic> json) {
    final id = json['Id'] as String?;
    if (id == null || id.isEmpty) return null;

    final capabilities = json['Capabilities'] is Map
        ? Map<String, dynamic>.from(json['Capabilities'] as Map)
        : null;

    List<String> parseStringList(dynamic raw) {
      if (raw is List) {
        return raw.whereType<String>().toList();
      }
      return const [];
    }

    final playableTypes = parseStringList(json['PlayableMediaTypes']);
    final capPlayableTypes = capabilities != null ? parseStringList(capabilities['PlayableMediaTypes']) : const <String>[];
    final mergedPlayableTypes = playableTypes.isNotEmpty ? playableTypes : capPlayableTypes;

    final commands = parseStringList(json['SupportedCommands']);
    final capCommands = capabilities != null ? parseStringList(capabilities['SupportedCommands']) : const <String>[];
    final mergedCommands = commands.isNotEmpty ? commands : capCommands;

    BaseItemDto? nowPlaying;
    if (json['NowPlayingItem'] is Map) {
      try {
        nowPlaying = BaseItemDto.fromJson(Map<String, dynamic>.from(json['NowPlayingItem'] as Map));
      } catch (_) {
        nowPlaying = null;
      }
    }

    RemotePlayState? playState;
    if (json['PlayState'] is Map) {
      try {
        playState = RemotePlayState.fromJson(Map<String, dynamic>.from(json['PlayState'] as Map));
      } catch (_) {
        playState = null;
      }
    }

    final queueFullItems = <BaseItemDto>[];
    if (json['NowPlayingQueueFullItems'] is List) {
      for (final item in json['NowPlayingQueueFullItems'] as List) {
        if (item is Map) {
          try {
            queueFullItems.add(BaseItemDto.fromJson(Map<String, dynamic>.from(item)));
          } catch (_) {}
        }
      }
    }

    final supportsMediaControl = (json['SupportsMediaControl'] as bool?) ??
        (capabilities?['SupportsMediaControl'] as bool?) ??
        false;
    final supportsRemoteControl = (json['SupportsRemoteControl'] as bool?) ?? false;

    return RemoteSession(
      id: id,
      deviceId: json['DeviceId'] as String?,
      deviceName: (json['DeviceName'] as String?) ?? '',
      client: (json['Client'] as String?) ?? '',
      userId: json['UserId'] as String?,
      userName: json['UserName'] as String?,
      applicationVersion: json['ApplicationVersion'] as String?,
      supportsRemoteControl: supportsRemoteControl,
      supportsMediaControl: supportsMediaControl,
      isActive: (json['IsActive'] as bool?) ?? false,
      playableMediaTypes: mergedPlayableTypes,
      supportedCommands: mergedCommands,
      nowPlayingItem: nowPlaying,
      playState: playState,
      nowPlayingQueueFullItems: queueFullItems,
    );
  }
}
