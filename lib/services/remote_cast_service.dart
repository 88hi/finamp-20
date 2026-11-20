import 'dart:async';
import 'dart:math';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/remote_cast_models.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

final _castLogger = Logger("RemoteCastService");

/// Maximum number of item IDs sent in a single Jellyfin /Sessions/{id}/Playing query string
/// to avoid exceeding reverse-proxy URL length limits.
const int _maxRemotePlayItems = 150;

/// Riverpod provider exposing the singleton [RemoteCastService].
final remoteCastServiceProvider = ChangeNotifierProvider<RemoteCastService>((ref) {
  return GetIt.instance<RemoteCastService>();
});

/// Manages Jellyfin Remote Control ("Cast" / "Play On") sessions, allowing Finamp
/// to discover and control playback on other Jellyfin clients.
class RemoteCastService extends ChangeNotifier {
  RemoteCastService() {
    FinampSettingsHelper.finampSettingsListener.addListener(_onSettingsChanged);
  }

  JellyfinApiHelper get _jellyfinApiHelper => GetIt.instance<JellyfinApiHelper>();
  FinampUserHelper get _finampUserHelper => GetIt.instance<FinampUserHelper>();

  RemoteSession? _activeSession;
  List<RemoteSession> _availableSessions = const [];
  bool _isLoadingSessions = false;
  String? _lastError;
  Duration _interpolatedPosition = Duration.zero;
  bool _isUserSeeking = false;

  Timer? _pollTimer;
  Timer? _positionTicker;
  Timer? _delayedRefreshTimer;
  int _consecutivePollFailures = 0;

  RemoteSession? get activeSession => _activeSession;
  bool get isCasting => _activeSession != null;
  List<RemoteSession> get availableSessions => _availableSessions;
  bool get isLoadingSessions => _isLoadingSessions;
  String? get lastError => _lastError;
  Duration get position => _interpolatedPosition;

  Duration get duration {
    final ticks = _activeSession?.nowPlayingItem?.runTimeTicks;
    if (ticks == null || ticks <= 0) return Duration.zero;
    return Duration(microseconds: ticks ~/ 10);
  }

  bool get isPlaying {
    final session = _activeSession;
    if (session == null || session.nowPlayingItem == null) return false;
    return !(session.playState?.isPaused ?? true);
  }

  void _onSettingsChanged() {
    if (FinampSettingsHelper.finampSettings.isOffline && isCasting) {
      _castLogger.info("Offline mode enabled, disconnecting remote cast session");
      disconnect(showSnackbar: false);
    }
  }

  /// Refreshes the list of controllable remote Jellyfin sessions on the server.
  Future<List<RemoteSession>> refreshSessions({bool silent = false}) async {
    if (FinampSettingsHelper.finampSettings.isOffline || _finampUserHelper.currentUser == null) {
      _availableSessions = const [];
      _lastError = null;
      notifyListeners();
      return const [];
    }

    if (!silent) {
      _isLoadingSessions = true;
      _lastError = null;
      notifyListeners();
    }

    try {
      final allSessions = await _jellyfinApiHelper.getControllableSessions(activeWithinSeconds: 960);
      final ownDeviceId = FinampSettingsHelper.finampSettings.deviceId;

      final filtered = allSessions.where((s) {
        if (s.deviceId != null && s.deviceId == ownDeviceId) return false;
        if (!s.isControllable) return false;
        if (!s.supportsAudio) return false;
        return true;
      }).toList();

      // Sort: currently connected first, then active/playing sessions, then by device name.
      filtered.sort((a, b) {
        if (_activeSession?.id == a.id) return -1;
        if (_activeSession?.id == b.id) return 1;
        final aPlaying = a.nowPlayingItem != null ? 0 : 1;
        final bPlaying = b.nowPlayingItem != null ? 0 : 1;
        if (aPlaying != bPlaying) return aPlaying.compareTo(bPlaying);
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });

      _availableSessions = filtered;
      _lastError = null;

      // Also update active session if it appears in the fetched list.
      if (_activeSession != null) {
        final updated = _findMatchingSession(allSessions, _activeSession!);
        if (updated != null) {
          _applyPolledSession(updated);
          _consecutivePollFailures = 0;
        }
      }

      return filtered;
    } catch (e, stack) {
      _castLogger.warning("Failed to fetch Jellyfin sessions: $e", e, stack);
      _lastError = e.toString();
      return _availableSessions;
    } finally {
      if (!silent) {
        _isLoadingSessions = false;
      }
      notifyListeners();
    }
  }

  RemoteSession? _findMatchingSession(List<RemoteSession> sessions, RemoteSession target) {
    for (final s in sessions) {
      if (s.id == target.id) return s;
    }
    if (target.deviceId != null) {
      for (final s in sessions) {
        if (s.deviceId == target.deviceId && s.client == target.client) return s;
      }
    }
    return null;
  }

  void _applyPolledSession(RemoteSession updated) {
    _activeSession = updated;
    if (!_isUserSeeking) {
      _interpolatedPosition = updated.playState?.position ?? Duration.zero;
    }
  }

  /// Connects to a remote Jellyfin session.
  /// Pauses local playback and optionally transfers the current local queue to the remote device.
  Future<void> connectToSession(
    RemoteSession session, {
    bool transferCurrentPlayback = false,
  }) async {
    _castLogger.info("Connecting to remote session: ${session.displayName} (${session.id})");

    // Capture local playback state before pausing if transferring.
    List<BaseItemDto>? localItems;
    int localIndex = 0;
    int? localPositionTicks;

    if (transferCurrentPlayback && GetIt.instance.isRegistered<QueueService>()) {
      final queueService = GetIt.instance<QueueService>();
      final queueInfo = queueService.getQueue();
      if (queueInfo.currentTrack != null) {
        final fullQueue = queueInfo.fullQueue;
        localItems = fullQueue
            .map((e) => e.baseItem)
            .whereType<BaseItemDto>()
            .toList();
        final currentTrackId = queueInfo.currentTrack!.baseItem.id;
        final idx = localItems.indexWhere((item) => item.id == currentTrackId);
        if (idx >= 0) localIndex = idx;
        if (GetIt.instance.isRegistered<MusicPlayerBackgroundTask>()) {
          final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
          final pos = audioHandler.playbackState.value.position;
          if (pos > Duration.zero) {
            localPositionTicks = pos.inMicroseconds * 10;
          }
        }
      }
    }

    // Pause local audio playback when casting to another device.
    if (GetIt.instance.isRegistered<MusicPlayerBackgroundTask>()) {
      try {
        final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
        if (audioHandler.playbackState.value.playing) {
          await audioHandler.pause();
        }
      } catch (e) {
        _castLogger.warning("Failed to pause local playback on cast connect: $e");
      }
    }

    _activeSession = session;
    _interpolatedPosition = session.playState?.position ?? Duration.zero;
    _consecutivePollFailures = 0;
    _startPolling();
    notifyListeners();

    GlobalSnackbar.message((context) {
      final l10n = AppLocalizations.of(context);
      return l10n?.castConnectedTo(session.displayName) ?? "Casting to ${session.displayName}";
    });

    if (transferCurrentPlayback && localItems != null && localItems.isNotEmpty) {
      await playItems(
        items: localItems,
        startingIndex: localIndex,
        startPositionTicks: localPositionTicks,
        playCommand: 'PlayNow',
      );
    } else {
      unawaited(_pollActiveSession());
    }
  }

  /// Transfers the current local Finamp queue to the connected remote session.
  Future<void> transferLocalQueueToRemote() async {
    if (!isCasting || !GetIt.instance.isRegistered<QueueService>()) return;
    final queueService = GetIt.instance<QueueService>();
    final queueInfo = queueService.getQueue();
    if (queueInfo.currentTrack == null) return;

    final items = queueInfo.fullQueue.map((e) => e.baseItem).whereType<BaseItemDto>().toList();
    if (items.isEmpty) return;

    int startIndex = 0;
    final currentTrackId = queueInfo.currentTrack!.baseItem.id;
    final idx = items.indexWhere((e) => e.id == currentTrackId);
    if (idx >= 0) startIndex = idx;

    int? posTicks;
    if (GetIt.instance.isRegistered<MusicPlayerBackgroundTask>()) {
      final audioHandler = GetIt.instance<MusicPlayerBackgroundTask>();
      final pos = audioHandler.playbackState.value.position;
      if (pos > Duration.zero) {
        posTicks = pos.inMicroseconds * 10;
      }
      if (audioHandler.playbackState.value.playing) {
        unawaited(audioHandler.pause());
      }
    }

    await playItems(
      items: items,
      startingIndex: startIndex,
      startPositionTicks: posTicks,
      playCommand: 'PlayNow',
    );
  }

  /// Disconnects from the current remote session and returns control to this device.
  void disconnect({bool showSnackbar = true}) {
    if (_activeSession == null) return;
    final previousName = _activeSession!.displayName;
    _castLogger.info("Disconnecting from remote session: $previousName");

    _stopPolling();
    _activeSession = null;
    _interpolatedPosition = Duration.zero;
    _isUserSeeking = false;
    _consecutivePollFailures = 0;
    notifyListeners();

    if (showSnackbar) {
      GlobalSnackbar.message((context) {
        final l10n = AppLocalizations.of(context);
        return l10n?.castDisconnected ?? "Disconnected from remote device";
      });
    }
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollActiveSession());
    });
    _positionTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_activeSession != null && !_isUserSeeking && isPlaying) {
        final next = _interpolatedPosition + const Duration(seconds: 1);
        final maxDur = duration;
        if (maxDur > Duration.zero && next > maxDur) {
          _interpolatedPosition = maxDur;
        } else {
          _interpolatedPosition = next;
        }
        notifyListeners();
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _positionTicker?.cancel();
    _positionTicker = null;
    _delayedRefreshTimer?.cancel();
    _delayedRefreshTimer = null;
  }

  void _scheduleQuickRefresh() {
    _delayedRefreshTimer?.cancel();
    _delayedRefreshTimer = Timer(const Duration(milliseconds: 450), () {
      unawaited(_pollActiveSession());
    });
  }

  Future<void> _pollActiveSession() async {
    final current = _activeSession;
    if (current == null || FinampSettingsHelper.finampSettings.isOffline) return;

    try {
      final sessions = await _jellyfinApiHelper.getControllableSessions(activeWithinSeconds: 960);
      if (_activeSession == null) return;

      final updated = _findMatchingSession(sessions, current);
      if (updated != null) {
        _consecutivePollFailures = 0;
        _applyPolledSession(updated);
        notifyListeners();
      } else {
        _consecutivePollFailures++;
        if (_consecutivePollFailures >= 5) {
          _castLogger.warning("Remote session ${current.displayName} is no longer available, disconnecting");
          disconnect(showSnackbar: true);
        }
      }
    } catch (e) {
      _castLogger.fine("Remote session poll failed: $e");
    }
  }

  /// Sends a list of items to play on the connected remote device.
  Future<void> playItems({
    required List<BaseItemDto> items,
    int startingIndex = 0,
    int? startPositionTicks,
    String playCommand = 'PlayNow',
  }) async {
    final session = _activeSession;
    if (session == null || items.isEmpty) return;

    // Slice around startingIndex if the list exceeds _maxRemotePlayItems
    List<BaseItemDto> slice = items;
    int adjustedStartIndex = startingIndex.clamp(0, items.length - 1);

    if (items.length > _maxRemotePlayItems) {
      final sliceStart = max(0, adjustedStartIndex - 10);
      final sliceEnd = min(items.length, sliceStart + _maxRemotePlayItems);
      slice = items.sublist(sliceStart, sliceEnd);
      adjustedStartIndex = adjustedStartIndex - sliceStart;
    }

    try {
      await _jellyfinApiHelper.sendRemotePlayCommand(
        sessionId: session.id,
        itemIds: slice.map((e) => e.id).toList(),
        playCommand: playCommand,
        startIndex: playCommand == 'PlayNow' ? adjustedStartIndex : null,
        startPositionTicks: playCommand == 'PlayNow' ? startPositionTicks : null,
      );

      if (playCommand == 'PlayNow') {
        final startingItem = slice[adjustedStartIndex];
        _activeSession = session.copyWith(
          nowPlayingItem: startingItem,
          playState: (session.playState ?? const RemotePlayState()).copyWith(
            isPaused: false,
            positionTicks: startPositionTicks ?? 0,
          ),
        );
        _interpolatedPosition = Duration(microseconds: (startPositionTicks ?? 0) ~/ 10);
        notifyListeners();
      }

      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.severe("Failed to send playItems to remote session: $e");
      GlobalSnackbar.error(e);
    }
  }

  Future<void> playNext(List<BaseItemDto> items) =>
      playItems(items: items, playCommand: 'PlayNext');

  Future<void> playLast(List<BaseItemDto> items) =>
      playItems(items: items, playCommand: 'PlayLast');

  Future<void> togglePlayPause() async {
    final session = _activeSession;
    if (session == null) return;
    final currentlyPaused = session.playState?.isPaused ?? false;
    final command = currentlyPaused ? 'Unpause' : 'Pause';

    // Optimistic update
    _activeSession = session.copyWith(
      playState: (session.playState ?? const RemotePlayState()).copyWith(
        isPaused: !currentlyPaused,
      ),
    );
    notifyListeners();

    try {
      await _jellyfinApiHelper.sendRemotePlaystateCommand(
        sessionId: session.id,
        command: command,
      );
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to togglePlayPause on remote session: $e");
      GlobalSnackbar.error(e);
      unawaited(_pollActiveSession());
    }
  }

  Future<void> stop() async {
    final session = _activeSession;
    if (session == null) return;
    try {
      await _jellyfinApiHelper.sendRemotePlaystateCommand(
        sessionId: session.id,
        command: 'Stop',
      );
      _activeSession = session.copyWith(clearNowPlayingItem: true);
      _interpolatedPosition = Duration.zero;
      notifyListeners();
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to stop remote session: $e");
      GlobalSnackbar.error(e);
    }
  }

  Future<void> nextTrack() async {
    final session = _activeSession;
    if (session == null) return;
    try {
      await _jellyfinApiHelper.sendRemotePlaystateCommand(
        sessionId: session.id,
        command: 'NextTrack',
      );
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to skip to next track on remote session: $e");
      GlobalSnackbar.error(e);
    }
  }

  Future<void> previousTrack() async {
    final session = _activeSession;
    if (session == null) return;
    try {
      await _jellyfinApiHelper.sendRemotePlaystateCommand(
        sessionId: session.id,
        command: 'PreviousTrack',
      );
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to skip to previous track on remote session: $e");
      GlobalSnackbar.error(e);
    }
  }

  void beginUserSeek(Duration previewPosition) {
    _isUserSeeking = true;
    _interpolatedPosition = previewPosition;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    final session = _activeSession;
    _isUserSeeking = false;
    if (session == null) return;
    _interpolatedPosition = position;
    notifyListeners();

    try {
      await _jellyfinApiHelper.sendRemotePlaystateCommand(
        sessionId: session.id,
        command: 'Seek',
        seekPositionTicks: position.inMicroseconds * 10,
      );
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to seek on remote session: $e");
      GlobalSnackbar.error(e);
    }
  }

  Future<void> setVolume(int volume) async {
    final session = _activeSession;
    if (session == null) return;
    final clamped = volume.clamp(0, 100);
    _activeSession = session.copyWith(
      playState: (session.playState ?? const RemotePlayState()).copyWith(
        volumeLevel: clamped,
        isMuted: clamped == 0,
      ),
    );
    notifyListeners();

    try {
      await _jellyfinApiHelper.sendRemoteGeneralCommand(
        sessionId: session.id,
        name: 'SetVolume',
        arguments: {'Volume': clamped.toString()},
      );
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to set remote volume: $e");
      GlobalSnackbar.error(e);
    }
  }

  Future<void> toggleMute() async {
    final session = _activeSession;
    if (session == null) return;
    final currentlyMuted = session.playState?.isMuted ?? false;
    _activeSession = session.copyWith(
      playState: (session.playState ?? const RemotePlayState()).copyWith(
        isMuted: !currentlyMuted,
      ),
    );
    notifyListeners();

    try {
      await _jellyfinApiHelper.sendRemoteGeneralCommand(
        sessionId: session.id,
        name: 'ToggleMute',
      );
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to toggle mute on remote session: $e");
      GlobalSnackbar.error(e);
    }
  }

  Future<void> cycleRepeatMode() async {
    final session = _activeSession;
    if (session == null) return;
    final current = session.playState?.repeatMode ?? 'RepeatNone';
    final next = switch (current) {
      'RepeatNone' => 'RepeatAll',
      'RepeatAll' => 'RepeatOne',
      _ => 'RepeatNone',
    };

    _activeSession = session.copyWith(
      playState: (session.playState ?? const RemotePlayState()).copyWith(
        repeatMode: next,
      ),
    );
    notifyListeners();

    try {
      await _jellyfinApiHelper.sendRemoteGeneralCommand(
        sessionId: session.id,
        name: 'SetRepeatMode',
        arguments: {'RepeatMode': next},
      );
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to set repeat mode on remote session: $e");
      GlobalSnackbar.error(e);
    }
  }

  Future<void> toggleShuffle() async {
    final session = _activeSession;
    if (session == null) return;
    final currentlyShuffled = (session.playState?.playbackOrder ?? 'Default') == 'Shuffle';
    final nextShuffleMode = currentlyShuffled ? 'Sorted' : 'Shuffle';
    final nextPlaybackOrder = currentlyShuffled ? 'Default' : 'Shuffle';

    _activeSession = session.copyWith(
      playState: (session.playState ?? const RemotePlayState()).copyWith(
        playbackOrder: nextPlaybackOrder,
      ),
    );
    notifyListeners();

    try {
      if (session.supportedCommands.contains('SetPlaybackOrder')) {
        await _jellyfinApiHelper.sendRemoteGeneralCommand(
          sessionId: session.id,
          name: 'SetPlaybackOrder',
          arguments: {'PlaybackOrder': nextPlaybackOrder},
        );
      } else {
        await _jellyfinApiHelper.sendRemoteGeneralCommand(
          sessionId: session.id,
          name: 'SetShuffleQueue',
          arguments: {'ShuffleMode': nextShuffleMode},
        );
      }
      _scheduleQuickRefresh();
    } catch (e) {
      _castLogger.warning("Failed to toggle shuffle on remote session: $e");
      GlobalSnackbar.error(e);
    }
  }

  @override
  void dispose() {
    FinampSettingsHelper.finampSettingsListener.removeListener(_onSettingsChanged);
    _stopPolling();
    super.dispose();
  }
}
