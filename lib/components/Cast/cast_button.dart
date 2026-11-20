import 'dart:async';

import 'package:finamp/components/Cast/cast_device_picker_sheet.dart';
import 'package:finamp/components/Cast/remote_controller_sheet.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/remote_cast_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// AppBar action button for Jellyfin Cast / Remote Control.
/// Opens the device picker when disconnected, or the remote controller sheet when connected.
class CastButton extends ConsumerWidget {
  const CastButton({
    super.key,
    this.iconSize = 26.0,
    this.color,
  });

  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = ref.watch(finampSettingsProvider.isOffline);
    final currentUser = ref.watch(FinampUserHelper.finampCurrentUserProvider);
    if (isOffline || currentUser == null) {
      return const SizedBox.shrink();
    }

    final castService = ref.watch(remoteCastServiceProvider);
    final isCasting = castService.isCasting;
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;

    return IconButton(
      tooltip: isCasting
          ? l10n.castConnectedTo(castService.activeSession!.displayName)
          : l10n.castTitle,
      onPressed: () {
        if (isCasting) {
          unawaited(showRemoteControllerSheet(context));
        } else {
          unawaited(showCastDevicePickerSheet(context));
        }
      },
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            isCasting ? Icons.cast_connected : TablerIcons.cast,
            size: iconSize,
            color: isCasting ? colorScheme.primary : color,
          ),
          if (isCasting)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
