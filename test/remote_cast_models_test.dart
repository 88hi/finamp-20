import 'package:finamp/models/remote_cast_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteSession.tryFromJson', () {
    test('parses a complete Jellyfin session payload', () {
      final session = RemoteSession.tryFromJson({
        'Id': 'session-123',
        'DeviceId': 'device-abc',
        'DeviceName': 'Living Room TV',
        'Client': 'Jellyfin Android TV',
        'ApplicationVersion': '0.18.0',
        'UserId': 'user-1',
        'UserName': 'Alice',
        'SupportsRemoteControl': true,
        'SupportsMediaControl': true,
        'IsActive': true,
        'PlayableMediaTypes': ['Audio', 'Video'],
        'SupportedCommands': ['SetVolume', 'ToggleMute', 'SetRepeatMode', 'SetShuffleQueue'],
        'PlayState': {
          'PositionTicks': 600000000, // 60 seconds
          'CanSeek': true,
          'IsPaused': false,
          'IsMuted': false,
          'VolumeLevel': 75,
          'RepeatMode': 'RepeatAll',
          'PlaybackOrder': 'Shuffle',
        },
        'NowPlayingItem': {
          'Id': 'track-1',
          'Name': 'Bohemian Rhapsody',
          'Type': 'Audio',
          'RunTimeTicks': 3540000000,
          'AlbumArtist': 'Queen',
        },
      });

      expect(session, isNotNull);
      expect(session!.id, 'session-123');
      expect(session.deviceId, 'device-abc');
      expect(session.displayName, 'Living Room TV');
      expect(session.isControllable, isTrue);
      expect(session.supportsAudio, isTrue);
      expect(session.supportsVolume, isTrue);
      expect(session.supportsMute, isTrue);
      expect(session.supportsRepeatMode, isTrue);
      expect(session.supportsShuffle, isTrue);
      expect(session.playState?.position, const Duration(seconds: 60));
      expect(session.playState?.volumeLevel, 75);
      expect(session.playState?.repeatMode, 'RepeatAll');
      expect(session.nowPlayingItem?.name, 'Bohemian Rhapsody');
    });

    test('handles minimal/nullable fields defensively without crashing', () {
      final session = RemoteSession.tryFromJson({
        'Id': 'session-min',
        'Client': 'Jellyfin Web',
        'Capabilities': {
          'SupportsMediaControl': true,
          'PlayableMediaTypes': ['Audio'],
          'SupportedCommands': ['SetVolume'],
        },
        'PlayState': <String, dynamic>{},
      });

      expect(session, isNotNull);
      expect(session!.displayName, 'Jellyfin Web');
      expect(session.isControllable, isTrue);
      expect(session.supportsAudio, isTrue);
      expect(session.supportsVolume, isTrue);
      expect(session.playState?.position, Duration.zero);
      expect(session.playState?.isPaused, isFalse);
      expect(session.nowPlayingItem, isNull);
    });

    test('returns null if Id is missing', () {
      expect(RemoteSession.tryFromJson({'DeviceName': 'Broken'}), isNull);
    });
  });
}
