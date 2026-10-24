import 'scrolling.dart';
import '../l10n/app_localizations.dart';
import 'pack_update_dialog.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;
import '../core/controller.dart';
import '../core/community_models.dart';
import 'theme.dart';
import 'byte_size.dart';
import 'download_speed.dart';

class ContentTaskCard extends StatefulWidget {
  final LauncherController controller;
  final ContentTask task;
  final bool allowPackUpdate;
  const ContentTaskCard({
    required this.controller,
    required this.task,
    this.allowPackUpdate = true,
    super.key,
  });
  @override
  State<ContentTaskCard> createState() => _ContentTaskCardState();
}

class _ContentTaskCardState extends State<ContentTaskCard> {
  bool working = false;
  String? error;
  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final task = widget.task;
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Tag(task.stage, accent: task.state == ContentTaskState.completed),
              if (task.state != ContentTaskState.running &&
                  task.state != ContentTaskState.waiting)
                IconButton(
                  key: ValueKey('dismiss-content-task-${task.id}'),
                  tooltip: AppLocalizations.of(context).textOrNull('移除任务记录'),
                  icon: const Icon(FIcons.x, size: 16),
                  onPressed:
                      working ||
                          !widget.allowPackUpdate &&
                              task.preparedInstance != null
                      ? null
                      : () => run(() async {
                          if (task.preparedInstance != null) {
                            await widget.controller.discardPackUpdate(task);
                          }
                          widget.controller.dismissContentTask(task);
                        }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${task.source.label} · ${tr(task.kind.label)}',
            style: TextStyle(color: c.muted, fontSize: 11),
          ),
          if (task.state == ContentTaskState.running) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: task.progress,
              minHeight: 4,
              color: c.accent,
              backgroundColor: c.raised,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                LText(
                  '${task.done} / ${task.total} · 已传输 ${formatByteSize(task.bytes)}${task.cachedBytes == 0 ? '' : ' · 复用缓存 ${formatByteSize(task.cachedBytes)}'}',
                  style: TextStyle(color: c.muted, fontSize: 11),
                ),
                DownloadSpeed(task.downloadRate),
              ],
            ),
            if (task.detail.isNotEmpty)
              LText(
                task.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.muted, fontSize: 10),
              ),
          ],
          if (task.state == ContentTaskState.waiting) ...[
            const SizedBox(height: 14),
            const LText('以下文件需要从项目页面下载后补齐。', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: AppScrollView(
                child: Column(
                  children: [
                    for (final missing in task.missing)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                missing.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            TextButton(
                              onPressed: missing.website.isEmpty
                                  ? null
                                  : () => launchUrl(
                                      Uri.parse(missing.website),
                                      mode: LaunchMode.externalApplication,
                                    ),
                              child: const LText('下载页面'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (task.error != null || error != null) ...[
            const SizedBox(height: 12),
            LSelectableText(
              error ?? task.error!,
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ],
          if (task.destination != null &&
              task.state == ContentTaskState.completed) ...[
            const SizedBox(height: 12),
            SelectableText(
              task.destination!,
              style: TextStyle(color: c.muted, fontSize: 11),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              if (widget.allowPackUpdate &&
                  task.preparedInstance != null &&
                  task.canRetry &&
                  task.updateTargetId != null)
                AppButton(
                  '继续整合包升级',
                  small: true,
                  onPressed: widget.controller.installing
                      ? null
                      : () => run(() async {
                          final instance = widget.controller.editableInstance(
                            task.updateTargetId!,
                          );
                          if (!mounted) return;
                          await showDialog<bool>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => PackUpdateDialog(
                              controller: widget.controller,
                              instance: instance,
                              existingTask: task,
                            ),
                          );
                        }),
                ),
              if (task.state == ContentTaskState.running ||
                  task.state == ContentTaskState.waiting)
                AppButton(
                  '取消',
                  secondary: true,
                  small: true,
                  onPressed: () => widget.controller.content.cancel(task),
                ),
              if (task.state == ContentTaskState.waiting)
                AppButton(
                  working ? '正在核对…' : '选择已下载文件',
                  icon: FIcons.folderOpen,
                  small: true,
                  onPressed: working
                      ? null
                      : () => run(() async {
                          final files = await openFiles(
                            acceptedTypeGroups: [
                              XTypeGroup(
                                label: tr('Mod 文件'),
                                extensions: ['jar', 'zip'],
                              ),
                            ],
                          );
                          if (files.isNotEmpty) {
                            await widget.controller.content.supplyFiles(
                              task,
                              files.map((f) => f.path).toList(),
                            );
                          }
                        }),
                ),
              if (task.canRetry &&
                  (task.state == ContentTaskState.failed ||
                      task.state == ContentTaskState.cancelled))
                AppButton(
                  '重试',
                  icon: FIcons.refreshCw,
                  small: true,
                  onPressed: working
                      ? null
                      : () => run(() => widget.controller.content.retry(task)),
                ),
              if (task.state == ContentTaskState.completed &&
                  task.destination != null)
                AppButton(
                  '打开位置',
                  icon: FIcons.folderOpen,
                  secondary: true,
                  small: true,
                  onPressed: () => widget.controller.openDirectory(
                    task.kind.hasTarget
                        ? p.dirname(task.destination!)
                        : task.destination!,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
