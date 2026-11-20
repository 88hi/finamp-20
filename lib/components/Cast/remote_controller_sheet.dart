import 'dart:async';

import 'package:finamp/components/Cast/cast_device_picker_sheet.dart';
import 'package:finamp/components/album_image.dart';
import 'package:finamp/components/print_duration.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/process_artist.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/remote_cast_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Opens the full remote controller modal bottom sheet for the active Jellyfin cast session.
Future<void> showRemoteControllerSheet(BuildContext context) async {
  FeedbackHelper.feedback(FeedbackType.selection);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => const _RemoteControllerSheet(),
  );
}

class _RemoteControllerSheet extends ConsumerStatefulWidget {
  const _RemoteControllerSheet();

  @override
  ConsumerState<_RemoteControllerSheet> createState() => _RemoteControllerSheetState();
}

class _RemoteControllerSheetState extends ConsumerState<_RemoteControllerSheet> {
  double? _dragSeekMs;
  double? _dragVolume;

  @override
  Widget build(BuildContext context) {
    final castService = ref.watch(remoteCastServiceProvider);
    final session = castService.activeSession;
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (session == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const SizedBox.shrink();
    }

    final item = session.nowPlayingItem;
    final playState = session.playState;
    final isPlaying = castService.isPlaying;
    final duration = castService.duration;
    final position = _dragSeekMs != null
        ? Duration(milliseconds: _dragSeekMs!.round())
        : castService.position;
    final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
    final currentMs = position.inMilliseconds.clamp(0, maxMs.round()).toDouble();
    final canSeek = (playState?.canSeek ?? false) && duration > Duration.zero;

    final volumeLevel = (_dragVolume ?? (playState?.volumeLevel?.toDouble() ?? 100.0)).clamp(0.0, 100.0);
    final isMuted = playState?.isMuted ?? false;
    final repeatMode = playState?.repeatMode ?? 'RepeatNone';
    final isShuffled = (playState?.playbackOrder ?? 'Default') == 'Shuffle';

    final hasLocalQueue = GetIt.instance.isRegistered<QueueService>() &&
        GetIt.instance<QueueService>().getCurrentTrack() != null;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top device header
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: colorScheme.primaryContainer,
                  child: Icon(
                    iconForRemoteSession(session),
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (session.clientSummary.isNotEmpty)
                        Text(
                          session.clientSummary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.castSwitchDevice,
                  icon: const Icon(TablerIcons.switch_horizontal),
                  onPressed: () {
                    Navigator.of(context).pop();
                    unawaited(showCastDevicePickerSheet(context));
                  },
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    FeedbackHelper.feedback(FeedbackType.light);
                    castService.disconnect();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(TablerIcons.cast_off, size: 18),
                  label: Text(l10n.castDisconnect),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // Album artwork
            SizedBox(
              width: 200,
              height: 200,
              child: item != null
                  ? AlbumImage(
                      item: item,
                      borderRadius: BorderRadius.circular(16),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        TablerIcons.cast,
                        size: 72,
                        color: colorScheme.primary.withValues(alpha: 0.7),
                      ),
                    ),
            ),

            const SizedBox(height: 16),

            // Track title & artist
            Text(
              item?.name ?? l10n.castReadyToPlay,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            if (item != null)
              Text(
                processArtist(item.albumArtist ?? item.artists?.join(', '), context),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
              ),

            const SizedBox(height: 16),

            // Seek bar
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              ),
              child: Slider(
                value: currentMs,
                min: 0,
                max: maxMs,
                onChanged: canSeek
                    ? (val) {
                        setState(() => _dragSeekMs = val);
                        castService.beginUserSeek(Duration(milliseconds: val.round()));
                      }
                    : null,
                onChangeEnd: canSeek
                    ? (val) {
                        setState(() => _dragSeekMs = null);
                        unawaited(castService.seek(Duration(milliseconds: val.round())));
                      }
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    printDuration(position, leadingZeroes: false),
                    style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  Text(
                    printDuration(duration, leadingZeroes: false),
                    style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Transport controls row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: l10n.shuffleAll,
                  onPressed: session.supportsShuffle
                      ? () {
                          FeedbackHelper.feedback(FeedbackType.light);
                          unawaited(castService.toggleShuffle());
                        }
                      : null,
                  icon: Icon(
                    TablerIcons.arrows_shuffle,
                    color: isShuffled ? colorScheme.primary : null,
                  ),
                ),
                IconButton(
                  iconSize: 32,
                  onPressed: item != null
                      ? () {
                          FeedbackHelper.feedback(FeedbackType.light);
                          unawaited(castService.previousTrack());
                        }
                      : null,
                  icon: const Icon(TablerIcons.player_skip_back_filled),
                ),
                FilledButton(
                  onPressed: item != null
                      ? () {
                          FeedbackHelper.feedback(FeedbackType.light);
                          unawaited(castService.togglePlayPause());
                        }
                      : null,
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(18),
                  ),
                  child: Icon(
                    isPlaying ? TablerIcons.player_pause_filled : TablerIcons.player_play_filled,
                    size: 32,
                  ),
                ),
                IconButton(
                  iconSize: 32,
                  onPressed: item != null
                      ? () {
                          FeedbackHelper.feedback(FeedbackType.light);
                          unawaited(castService.nextTrack());
                        }
                      : null,
                  icon: const Icon(TablerIcons.player_skip_forward_filled),
                ),
                IconButton(
                  onPressed: session.supportsRepeatMode
                      ? () {
                          FeedbackHelper.feedback(FeedbackType.light);
                          unawaited(castService.cycleRepeatMode());
                        }
                      : null,
                  icon: Icon(
                    repeatMode == 'RepeatOne' ? TablerIcons.repeat_once : TablerIcons.repeat,
                    color: repeatMode != 'RepeatNone' ? colorScheme.primary : null,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Secondary actions: Stop & Transfer local queue
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (item != null)
                  OutlinedButton.icon(
                    onPressed: () {
                      FeedbackHelper.feedback(FeedbackType.light);
                      unawaited(castService.stop());
                    },
                    icon: const Icon(TablerIcons.player_stop_filled, size: 18),
                    label: Text(l10n.castStop),
                  ),
                if (hasLocalQueue)
                  OutlinedButton.icon(
                    onPressed: () {
                      FeedbackHelper.feedback(FeedbackType.selection);
                      unawaited(castService.transferLocalQueueToRemote());
                    },
                    icon: const Icon(TablerIcons.send, size: 18),
                    label: Text(l10n.castTransferQueue),
                  ),
              ],
            ),

            // Volume slider
            if (session.supportsVolume) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  IconButton(
                    onPressed: session.supportsMute
                        ? () {
                            FeedbackHelper.feedback(FeedbackType.light);
                            unawaited(castService.toggleMute());
                          }
                        : null,
                    icon: Icon(
                      isMuted || volumeLevel == 0
                          ? TablerIcons.volume_off
                          : volumeLevel < 50
                              ? TablerIcons.volume_2
                              : TablerIcons.volume,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: isMuted ? 0 : volumeLevel,
                      min: 0,
                      max: 100,
                      onChanged: (v) => setState(() => _dragVolume = v),
                      onChangeEnd: (v) {
                        setState(() => _dragVolume = null);
                        unawaited(castService.setVolume(v.round()));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '${(isMuted ? 0 : volumeLevel).round()}%',
                      textAlign: TextAlign.end,
                      style: textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],

            // Remote queue preview (if reported by Jellyfin server)
            if (session.nowPlayingQueueFullItems.length > 1) ...[
              const SizedBox(height: 16),
              const Divider(),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    l10n.castUpNext,
                    style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              ...session.nowPlayingQueueFullItems.take(8).map((qItem) {
                final isCurrent = item?.id == qItem.id;
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: SizedBox(
                    width: 40,
                    height: 40,
                    child: AlbumImage(
                      item: qItem,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  title: Text(
                    qItem.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                      color: isCurrent ? colorScheme.primary : null,
                    ),
                  ),
                  subtitle: Text(
                    processArtist(qItem.albumArtist ?? qItem.artists?.join(', '), context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: isCurrent
                      ? Icon(TablerIcons.volume, size: 18, color: colorScheme.primary)
                      : null,
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
