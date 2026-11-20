import 'dart:async';

import 'package:finamp/components/Cast/remote_controller_sheet.dart';
import 'package:finamp/components/album_image.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/process_artist.dart';
import 'package:finamp/services/remote_cast_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Compact mini-player bar shown in place of the local NowPlayingBar while
/// Finamp is actively casting to a remote Jellyfin device.
class RemoteCastNowPlayingBar extends ConsumerWidget {
  const RemoteCastNowPlayingBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final castService = ref.watch(remoteCastServiceProvider);
    final session = castService.activeSession;
    if (session == null) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final item = session.nowPlayingItem;
    final isPlaying = castService.isPlaying;
    final duration = castService.duration;
    final position = castService.position;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.only(left: 12.0, bottom: 12.0, right: 12.0),
      child: Material(
        elevation: 6.0,
        borderRadius: BorderRadius.circular(12.0),
        clipBehavior: Clip.antiAlias,
        color: colorScheme.primaryContainer,
        child: InkWell(
          onTap: () => unawaited(showRemoteControllerSheet(context)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 64.0,
                child: Row(
                  children: [
                    // Artwork or Cast icon
                    SizedBox(
                      width: 64.0,
                      height: 64.0,
                      child: item != null
                          ? AlbumImage(
                              item: item,
                              borderRadius: BorderRadius.zero,
                            )
                          : Container(
                              color: colorScheme.primary.withValues(alpha: 0.15),
                              child: Icon(
                                Icons.cast_connected,
                                color: colorScheme.onPrimaryContainer,
                                size: 28,
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.cast_connected,
                                size: 13,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  l10n.castConnectedTo(session.displayName),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item?.name ?? l10n.castReadyToPlay,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                          if (item != null)
                            Text(
                              processArtist(item.albumArtist ?? item.artists?.join(', '), context),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onPrimaryContainer.withValues(alpha: 0.78),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (item != null) ...[
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        color: colorScheme.onPrimaryContainer,
                        onPressed: () {
                          FeedbackHelper.feedback(FeedbackType.light);
                          unawaited(castService.togglePlayPause());
                        },
                        icon: Icon(
                          isPlaying
                              ? TablerIcons.player_pause_filled
                              : TablerIcons.player_play_filled,
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        color: colorScheme.onPrimaryContainer,
                        onPressed: () {
                          FeedbackHelper.feedback(FeedbackType.light);
                          unawaited(castService.nextTrack());
                        },
                        icon: const Icon(TablerIcons.player_skip_forward_filled),
                      ),
                    ],
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: l10n.castDisconnect,
                      color: colorScheme.onPrimaryContainer,
                      onPressed: () {
                        FeedbackHelper.feedback(FeedbackType.light);
                        castService.disconnect();
                      },
                      icon: const Icon(TablerIcons.x, size: 20),
                    ),
                  ],
                ),
              ),
              if (item != null && duration > Duration.zero)
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 2.5,
                  backgroundColor: colorScheme.onPrimaryContainer.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
