import 'scrolling.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../core/controller.dart';
import '../l10n/app_localizations.dart';
import 'byte_size.dart';
import 'download_speed.dart';
import 'theme.dart';

class LauncherUpdatePanel extends StatelessWidget {
  final LauncherController controller;
  final String channel;
  final bool canRestart;
  const LauncherUpdatePanel({
    required this.controller,
    required this.channel,
    this.canRestart = true,
    super.key,
  });

  Future<void> restart(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('重启并更新 FYL'),
        content: const LText('FYL 将关闭并应用已下载的更新，完成后自动重新打开。游戏和账号数据会保留。'),
        actions: [
          AppButton(
            '取消',
            secondary: true,
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton('重启并更新', onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.prepareLauncherUpdate();
      await windowManager.destroy();
    } catch (error) {
      await controller.launcherUpdater.abortHandoff();
      controller.launcherUpdater.error = error.toString();
      controller.notifyListeners();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final updater = controller.launcherUpdater, release = updater.available;
      Future<void> run(Future<void> Function() operation) async {
        try {
          await operation();
        } catch (error) {
          updater.error = error.toString();
          controller.notifyListeners();
        }
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LText(
            '当前版本：${updater.development ? tr('开发版') : updater.currentVersion}',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              AppButton(
                updater.checking ? '正在检查…' : '检查启动器更新',
                small: true,
                secondary: true,
                onPressed: updater.checking || updater.busy
                    ? null
                    : () => run(() => updater.check(channel: channel)),
              ),
              if (release != null)
                AppButton(
                  '发布页面',
                  small: true,
                  secondary: true,
                  onPressed: () => launchUrl(
                    Uri.parse(release.website),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              if (release?.asset != null &&
                  release?.digest != null &&
                  !updater.development)
                AppButton(
                  '下载更新',
                  small: true,
                  onPressed: updater.busy ? null : () => run(updater.download),
                ),
              if (updater.ready)
                AppButton(
                  '重启并更新',
                  small: true,
                  onPressed:
                      !canRestart || controller.installing || controller.running
                      ? null
                      : () => restart(context),
                ),
            ],
          ),
          if (updater.checking)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: LinearProgressIndicator(),
            ),
          if (updater.detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: LText(updater.detail),
            ),
          if (release != null) ...[
            const SizedBox(height: 10),
            LText('发现新版本 ${release.version}'),
            Tag(release.prerelease ? '测试版' : '正式版'),
            if (release.asset == null) const LText('没有适用于当前系统的更新包。'),
            if (release.asset != null && release.digest == null)
              const LText('更新包缺少 SHA-256，无法自动安装，请从发布页面下载。'),
            if (release.notes.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: AppScrollView(child: SelectableText(release.notes)),
              ),
          ],
          if (updater.development) const LText('开发版请通过源码或发布页面更新。'),
          if (updater.ready) ...[
            const SizedBox(height: 10),
            LText('已下载更新 ${updater.downloadedRelease!.version}'),
            if (!canRestart) const LText('请先保存或放弃尚未保存的设置。'),
            if (controller.running ||
                controller.installing && !updater.applying)
              const LText('请先结束下载任务并关闭正在运行的游戏，再更新启动器。'),
          ],
          if (updater.downloading) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: updater.progress),
            LText(updater.status),
            DownloadSpeed(updater.rate),
          ],
          if (updater.applying) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(),
            LText(updater.status),
          ],
          if (updater.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: LText(
                updater.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      );
    },
  );
}

class LauncherUpdateTaskCard extends StatelessWidget {
  final LauncherController controller;
  final VoidCallback showSettings;
  const LauncherUpdateTaskCard({
    required this.controller,
    required this.showSettings,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final updater = controller.launcherUpdater;
    return Surface(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FIcons.download),
              const SizedBox(width: 10),
              Expanded(
                child: LText(
                  'FYL 启动器更新 ${updater.downloadedRelease?.version ?? ''}',
                ),
              ),
              if (!updater.busy)
                IconButton(
                  icon: const Icon(FIcons.x, size: 16),
                  tooltip: tr('移除任务'),
                  onPressed: updater.dismiss,
                ),
            ],
          ),
          const SizedBox(height: 10),
          LText(updater.status),
          if (updater.downloading) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: updater.progress),
            const SizedBox(height: 8),
            DownloadSpeed(updater.rate),
          ],
          LText('已传输 ${formatByteSize(updater.bytes)}'),
          if (updater.error != null)
            LText(
              updater.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            children: [
              if (updater.downloading)
                AppButton(
                  '取消',
                  small: true,
                  secondary: true,
                  onPressed: updater.cancel,
                ),
              if (!updater.busy && !updater.ready)
                AppButton(
                  '重试',
                  small: true,
                  onPressed: () {
                    unawaited(
                      updater.download().catchError((Object error) {
                        updater.error = error.toString();
                        controller.notifyListeners();
                      }),
                    );
                  },
                ),
              if (updater.ready)
                AppButton('前往设置完成更新', small: true, onPressed: showSettings),
            ],
          ),
        ],
      ),
    );
  }
}
