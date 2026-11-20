import 'dart:async';

import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/models/remote_cast_models.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/remote_cast_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

/// Returns an appropriate icon for a Jellyfin client/device name.
IconData iconForRemoteSession(RemoteSession session) {
  final combined = '${session.client} ${session.deviceName}'.toLowerCase();
  if (combined.contains('tv') || combined.contains('roku') || combined.contains('chromecast') || combined.contains('kodi')) {
    return TablerIcons.device_tv;
  }
  if (combined.contains('web') || combined.contains('chrome') || combined.contains('firefox') || combined.contains('safari') || combined.contains('edge')) {
    return TablerIcons.browser;
  }
  if (combined.contains('android') || combined.contains('iphone') || combined.contains('ios') || combined.contains('mobile')) {
    return TablerIcons.device_mobile;
  }
  if (combined.contains('ipad') || combined.contains('tablet')) {
    return TablerIcons.device_tablet;
  }
  if (combined.contains('speaker') || combined.contains('sonos') || combined.contains('dlna') || combined.contains('audio')) {
    return TablerIcons.device_speaker;
  }
  if (combined.contains('windows') || combined.contains('mac') || combined.contains('linux') || combined.contains('desktop') || combined.contains('media player')) {
    return TablerIcons.device_desktop;
  }
  return TablerIcons.cast;
}

/// Shows the Jellyfin "Play On / Cast" device selection bottom sheet.
Future<void> showCastDevicePickerSheet(BuildContext context) async {
  FeedbackHelper.feedback(FeedbackType.selection);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => const _CastDevicePickerSheet(),
  );
}

class _CastDevicePickerSheet extends ConsumerStatefulWidget {
  const _CastDevicePickerSheet();

  @override
  ConsumerState<_CastDevicePickerSheet> createState() => _CastDevicePickerSheetState();
}

class _CastDevicePickerSheetState extends ConsumerState<_CastDevicePickerSheet> {
  bool _transferPlayback = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(GetIt.instance<RemoteCastService>().refreshSessions());
    });
  }

  bool get _hasLocalQueue {
    if (!GetIt.instance.isRegistered<QueueService>()) return false;
    return GetIt.instance<QueueService>().getCurrentTrack() != null;
  }

  @override
  Widget build(BuildContext context) {
    final castService = ref.watch(remoteCastServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final activeSession = castService.activeSession;
    final hasLocalQueue = _hasLocalQueue;

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  Icon(TablerIcons.cast, color: colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.castTitle,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.refresh,
                    onPressed: castService.isLoadingSessions
                        ? null
                        : () {
                            FeedbackHelper.feedback(FeedbackType.light);
                            unawaited(castService.refreshSessions());
                          },
                    icon: castService.isLoadingSessions
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(TablerIcons.refresh),
                  ),
                ],
              ),
            ),

            if (hasLocalQueue && !castService.isCasting)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: CheckboxListTile(
                  dense: true,
                  value: _transferPlayback,
                  onChanged: (v) => setState(() => _transferPlayback = v ?? true),
                  title: Text(
                    l10n.castTransferCurrentPlayback,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ),

            const Divider(height: 1),

            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // "This Device" option
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: !castService.isCasting
                          ? colorScheme.primaryContainer
                          : colorScheme.surfaceContainerHighest,
                      child: Icon(
                        TablerIcons.device_mobile,
                        color: !castService.isCasting
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                    title: Text(
                      l10n.castThisDevice,
                      style: TextStyle(
                        fontWeight: !castService.isCasting ? FontWeight.w600 : FontWeight.normal,
                        color: !castService.isCasting ? colorScheme.primary : null,
                      ),
                    ),
                    subtitle: Text(l10n.castThisDeviceSubtitle),
                    trailing: !castService.isCasting
                        ? Icon(TablerIcons.check, color: colorScheme.primary)
                        : null,
                    onTap: () {
                      FeedbackHelper.feedback(FeedbackType.selection);
                      if (castService.isCasting) {
                        castService.disconnect();
                      }
                      Navigator.of(context).pop();
                    },
                  ),

                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Divider(height: 1),
                  ),

                  if (castService.isLoadingSessions && castService.availableSessions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (castService.availableSessions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
                      child: Column(
                        children: [
                          Icon(
                            TablerIcons.cast_off,
                            size: 40,
                            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.castNoDevicesFound,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    )
                  else
                    for (final session in castService.availableSessions)
                      _buildSessionTile(
                        context: context,
                        session: session,
                        isSelected: activeSession?.id == session.id,
                        onTap: () async {
                          FeedbackHelper.feedback(FeedbackType.selection);
                          final shouldTransfer = _transferPlayback &&
                              hasLocalQueue &&
                              !castService.isCasting &&
                              session.nowPlayingItem == null;
                          Navigator.of(context).pop();
                          await castService.connectToSession(
                            session,
                            transferCurrentPlayback: shouldTransfer,
                          );
                        },
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionTile({
    required BuildContext context,
    required RemoteSession session,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final playingName = session.nowPlayingItem?.name;
    final subtitleParts = <String>[
      if (session.client.isNotEmpty) session.client,
      if (playingName != null && playingName.isNotEmpty) '▶ $playingName',
    ];

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isSelected
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        child: Icon(
          iconForRemoteSession(session),
          color: isSelected
              ? colorScheme.onPrimaryContainer
              : colorScheme.onSurfaceVariant,
        ),
      ),
      title: Text(
        session.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          color: isSelected ? colorScheme.primary : null,
        ),
      ),
      subtitle: subtitleParts.isNotEmpty
          ? Text(
              subtitleParts.join(' • '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: isSelected
          ? Icon(TablerIcons.check, color: colorScheme.primary)
          : Icon(TablerIcons.chevron_right, color: colorScheme.onSurfaceVariant),
      onTap: onTap,
    );
  }
}
