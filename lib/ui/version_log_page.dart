import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;

import '../core/controller.dart';
import '../core/crash_report.dart';
import 'game_failure_dialog.dart'
    show DiagnosticSavePicker, diagnosticSavePicker;
import 'theme.dart';

class VersionLogPage extends StatefulWidget {
  final LauncherController controller;
  final String instanceId;
  final VoidCallback onBack;
  final DiagnosticSavePicker savePicker;
  const VersionLogPage({
    required this.controller,
    required this.instanceId,
    required this.onBack,
    this.savePicker = diagnosticSavePicker,
    super.key,
  });
  @override
  State<VersionLogPage> createState() => _VersionLogPageState();
}

class _VersionLogPageState extends State<VersionLogPage> {
  bool loading = true;
  bool exporting = false;
  String? error;
  String? exportError;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.controller.loadVersionLog(widget.instanceId);
    } catch (failure) {
      error = '读取日志失败：$failure';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> exportLog() async {
    final log = widget.controller.versionLogs[widget.instanceId];
    if (log == null) return;
    setState(() {
      exporting = true;
      exportError = null;
    });
    try {
      var destination = await widget.savePicker('FYL-game.log', 'log');
      if (destination == null) return;
      if (!destination.toLowerCase().endsWith('.log')) destination += '.log';
      await exportSanitizedLog(log.path, destination);
    } catch (failure) {
      if (mounted) setState(() => exportError = '导出日志失败：$failure');
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = LauncherColors.of(context);
      final controller = widget.controller;
      final instance = controller.instances
          .where((item) => item.id == widget.instanceId)
          .firstOrNull;
      final log = controller.versionLogs[widget.instanceId];
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '返回版本列表',
                  onPressed: widget.onBack,
                  icon: const Icon(FIcons.arrowLeft, size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${instance?.name ?? '版本'} · 运行日志',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (log != null) ...[
              Text(
                controller.isVersionLogLive(log)
                    ? '正在记录游戏输出'
                    : log.exitCode == null
                    ? '上次启动的日志'
                    : '上次启动 · 退出码 ${log.exitCode}',
                style: TextStyle(color: c.muted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppButton(
                    '复制日志',
                    icon: FIcons.copy,
                    secondary: true,
                    small: true,
                    onPressed: () => Clipboard.setData(
                      ClipboardData(
                        text: sanitizeDiagnosticText(log.lines.join('\n')),
                      ),
                    ),
                  ),
                  AppButton(
                    '日志目录',
                    icon: FIcons.folderOpen,
                    secondary: true,
                    small: true,
                    onPressed: () =>
                        controller.openDirectory(p.dirname(log.path)),
                  ),
                  AppButton(
                    exporting ? '正在导出…' : '导出日志',
                    icon: FIcons.download,
                    secondary: true,
                    small: true,
                    onPressed: exporting ? null : exportLog,
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            if (exportError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  exportError!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ),
            Expanded(
              child: Surface(
                padding: const EdgeInsets.all(16),
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : error != null || log == null
                    ? Center(child: Text(error ?? '此版本还没有启动日志。'))
                    : SelectionArea(
                        child: ListView.builder(
                          reverse: true,
                          itemCount: log.lines.length,
                          itemBuilder: (context, index) => Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Text(
                              log.lines[log.lines.length - 1 - index],
                              style: TextStyle(
                                color: c.secondaryText,
                                fontFamily: 'monospace',
                                fontSize: 13,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
