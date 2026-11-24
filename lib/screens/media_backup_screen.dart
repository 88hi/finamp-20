import 'dart:async';

import 'package:file_sizes/file_sizes.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/media_backup_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:get_it/get_it.dart';

class MediaBackupScreen extends ConsumerStatefulWidget {
  const MediaBackupScreen({super.key});

  static const routeName = "/media-backup";

  @override
  ConsumerState<MediaBackupScreen> createState() => _MediaBackupScreenState();
}

class _MediaBackupScreenState extends ConsumerState<MediaBackupScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final service = GetIt.instance<MediaBackupService>();
      await service.initialize();
      unawaited(service.checkServerStatus());
      if (service.isSupported) {
        await service.requestPermissionsAndLoadFolders();
      }
    });
  }

  Future<void> _handleStartBackup({List<MediaBackupItem>? retryItems}) async {
    final service = GetIt.instance<MediaBackupService>();
    final l10n = AppLocalizations.of(context)!;
    FeedbackHelper.feedback(FeedbackType.selection);

    final errCode = await service.startBackup(retryItems: retryItems);
    if (!mounted) return;
    if (errCode != null) {
      final msg = switch (errCode) {
        "WIFI_REQUIRED" => l10n.mediaBackupWifiRequired,
        "CHARGING_REQUIRED" => l10n.mediaBackupChargingRequired,
        "PLUGIN_NOT_INSTALLED" => l10n.mediaBackupPluginNotInstalled,
        "PLUGIN_NOT_CONFIGURED" => l10n.mediaBackupPluginNotConfigured,
        "NO_FOLDERS_SELECTED" => l10n.mediaBackupNoFoldersSelected,
        _ => errCode,
      };
      GlobalSnackbar.message((_) => msg);
    } else if (service.failedItems.isEmpty) {
      GlobalSnackbar.message(
        (_) => l10n.mediaBackupCompletedSummary(service.uploadedCount, service.skippedCount),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(mediaBackupServiceProvider);
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.mediaBackupTitle),
        actions: [
          IconButton(
            tooltip: l10n.refresh,
            onPressed: service.isBackingUp
                ? null
                : () async {
                    FeedbackHelper.feedback(FeedbackType.light);
                    unawaited(service.checkServerStatus());
                    if (service.hasPermission) {
                      await service.loadFolders();
                    } else {
                      await service.requestPermissionsAndLoadFolders();
                    }
                  },
            icon: const Icon(TablerIcons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'clear_cache') {
                await service.clearLocalUploadCache();
                if (!context.mounted) return;
                GlobalSnackbar.message((_) => l10n.mediaBackupCacheCleared);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'clear_cache',
                enabled: !service.isBackingUp,
                child: Text(l10n.mediaBackupClearLocalCache),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // 1. Server plugin status card
          _buildServerStatusCard(context, service, l10n, colorScheme, textTheme),
          const SizedBox(height: 12),

          // 2. Manual backup action & progress card
          _buildActionCard(context, service, l10n, colorScheme, textTheme),
          const SizedBox(height: 12),

          // 3. Backup options card
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                  child: Text(
                    l10n.mediaBackupOptionsTitle,
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                SwitchListTile(
                  title: Text(l10n.mediaBackupIncludePhotos),
                  secondary: const Icon(TablerIcons.photo),
                  value: service.includePhotos,
                  onChanged: service.isBackingUp ? null : service.setIncludePhotos,
                ),
                SwitchListTile(
                  title: Text(l10n.mediaBackupIncludeVideos),
                  secondary: const Icon(TablerIcons.video),
                  value: service.includeVideos,
                  onChanged: service.isBackingUp ? null : service.setIncludeVideos,
                ),
                SwitchListTile(
                  title: Text(l10n.mediaBackupWifiOnly),
                  secondary: const Icon(TablerIcons.wifi),
                  value: service.wifiOnly,
                  onChanged: service.isBackingUp ? null : service.setWifiOnly,
                ),
                SwitchListTile(
                  title: Text(l10n.mediaBackupChargingOnly),
                  secondary: const Icon(TablerIcons.battery_charging),
                  value: service.chargingOnly,
                  onChanged: service.isBackingUp ? null : service.setChargingOnly,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 4. Failed items card (if any)
          if (service.failedItems.isNotEmpty) ...[
            _buildFailedCard(context, service, l10n, colorScheme, textTheme),
            const SizedBox(height: 12),
          ],

          // 5. Folder selection card
          _buildFoldersCard(context, service, l10n, colorScheme, textTheme),
        ],
      ),
    );
  }

  Widget _buildServerStatusCard(
    BuildContext context,
    MediaBackupService service,
    AppLocalizations l10n,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final status = service.serverStatus;
    final stats = service.serverStats;

    IconData icon;
    Color iconColor;
    String title;
    String subtitle;

    if (service.isCheckingServer && status == null) {
      icon = TablerIcons.cloud;
      iconColor = colorScheme.primary;
      title = l10n.mediaBackupCheckingServer;
      subtitle = '';
    } else if (status != null && status.installed && status.configured) {
      icon = TablerIcons.cloud_check;
      iconColor = Colors.green;
      title = l10n.mediaBackupPluginReady;
      if (stats != null && stats.totalFiles > 0) {
        subtitle = l10n.mediaBackupServerStatsSummary(
          stats.photoCount,
          stats.videoCount,
          FileSize.getSize(stats.totalBytes),
        );
      } else {
        subtitle = l10n.mediaBackupPluginVersion(status.version);
      }
    } else if (status != null && status.installed && !status.configured) {
      icon = TablerIcons.alert_triangle;
      iconColor = Colors.orange;
      title = l10n.mediaBackupPluginNotConfigured;
      subtitle = l10n.mediaBackupPluginNotConfiguredHint;
    } else {
      icon = TablerIcons.cloud_off;
      iconColor = colorScheme.error;
      title = l10n.mediaBackupPluginNotInstalled;
      subtitle = status?.errorMessage ?? l10n.mediaBackupPluginNotInstalledHint;
    }

    return Card(
      child: ListTile(
        leading: Icon(icon, color: iconColor, size: 30),
        title: Text(title, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
        trailing: service.isCheckingServer
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
    );
  }

  Widget _buildActionCard(
    BuildContext context,
    MediaBackupService service,
    AppLocalizations l10n,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final speedStr = service.uploadSpeedBytesPerSec > 0
        ? '${FileSize.getSize(service.uploadSpeedBytesPerSec.round())}/s'
        : '';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (service.isBackingUp) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      service.currentFileName ?? l10n.mediaBackupScanning,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (speedStr.isNotEmpty)
                    Text(
                      speedStr,
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.primary),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: service.totalToProcess > 0 ? service.overallProgress : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.mediaBackupProgressSummary(
                  service.processedCount,
                  service.totalToProcess,
                  service.uploadedCount,
                  service.skippedCount,
                ),
                style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  FeedbackHelper.feedback(FeedbackType.light);
                  service.cancelBackup();
                },
                icon: const Icon(TablerIcons.player_stop),
                label: Text(l10n.mediaBackupStop),
              ),
            ] else ...[
              if (service.totalToProcess > 0) ...[
                Text(
                  l10n.mediaBackupCompletedSummary(service.uploadedCount, service.skippedCount),
                  style: textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
                ),
                const SizedBox(height: 10),
              ],
              FilledButton.icon(
                onPressed: service.hasPermission ? () => unawaited(_handleStartBackup()) : null,
                icon: const Icon(TablerIcons.cloud_upload),
                label: Text(l10n.mediaBackupStartButton),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFailedCard(
    BuildContext context,
    MediaBackupService service,
    AppLocalizations l10n,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Card(
      color: colorScheme.errorContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(TablerIcons.alert_circle, color: colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.mediaBackupFailedCount(service.failedItems.length),
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.error,
                    ),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: service.isBackingUp
                      ? null
                      : () => unawaited(
                            _handleStartBackup(
                              retryItems: service.failedItems.map((e) => e.item).toList(),
                            ),
                          ),
                  child: Text(l10n.mediaBackupRetryFailed),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...service.failedItems.take(5).map(
                  (f) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• ${f.item.fileName}: ${f.error}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildFoldersCard(
    BuildContext context,
    MediaBackupService service,
    AppLocalizations l10n,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.mediaBackupSelectFoldersTitle,
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${service.selectedBucketIds.length}/${service.folders.length}',
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (!service.hasPermission)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.mediaBackupPermissionHint,
                    style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => unawaited(service.requestPermissionsAndLoadFolders()),
                    icon: const Icon(TablerIcons.lock_open),
                    label: Text(l10n.mediaBackupGrantPermission),
                  ),
                ],
              ),
            )
          else if (service.isLoadingFolders)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (service.folders.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l10n.mediaBackupNoFoldersFound,
                style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            )
          else
            ...service.folders.map((folder) {
              final checked = service.selectedBucketIds.contains(folder.bucketId);
              return CheckboxListTile(
                value: checked,
                onChanged: service.isBackingUp
                    ? null
                    : (val) => unawaited(service.toggleBucket(folder.bucketId, val ?? false)),
                title: Text(folder.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  l10n.mediaBackupFolderSummary(
                    folder.photoCount,
                    folder.videoCount,
                    FileSize.getSize(folder.totalBytes),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
