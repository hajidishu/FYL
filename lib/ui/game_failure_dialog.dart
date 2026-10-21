import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../core/crash_report.dart';
import 'theme.dart';

typedef DiagnosticSavePicker =
    Future<String?> Function(String name, String extension);

Future<String?> diagnosticSavePicker(String name, String extension) async =>
    (await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [
        XTypeGroup(
          label: extension == 'zip' ? 'FYL 错误报告' : '游戏日志',
          extensions: [extension],
        ),
      ],
    ))?.path;

class GameFailureDialog extends StatefulWidget {
  final GameFailure failure;
  final DiagnosticSavePicker savePicker;
  const GameFailureDialog({
    required this.failure,
    this.savePicker = diagnosticSavePicker,
    super.key,
  });
  @override
  State<GameFailureDialog> createState() => _GameFailureDialogState();
}

class _GameFailureDialogState extends State<GameFailureDialog> {
  bool working = false;
  String? message;
  bool failed = false;

  Future<void> export(bool report) async {
    setState(() {
      working = true;
      message = null;
      failed = false;
    });
    try {
      final extension = report ? 'zip' : 'log';
      final name = widget.failure.instanceName.replaceAll(
        RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
        '_',
      );
      var location = await widget.savePicker(
        '$name-${report ? 'error-report' : 'game'}.$extension',
        extension,
      );
      if (location == null) return;
      if (!location.toLowerCase().endsWith('.$extension')) {
        location += '.$extension';
      }
      if (report) {
        await widget.failure.exportReport(location);
      } else {
        await widget.failure.exportLog(location);
      }
      if (mounted) setState(() => message = '已导出：$location');
    } catch (error) {
      if (mounted) {
        setState(() {
          failed = true;
          message = '导出失败：$error';
        });
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return PopScope(
      canPop: !working,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          '${widget.failure.instanceName}非正常退出',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '下方可导出错误报告和游戏日志，如果你需要向他人求助请发送错误报告而不是此页面的截图',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.65,
                  color: c.secondaryText,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '退出码：${widget.failure.exitCode}',
                style: TextStyle(fontSize: 13, color: c.muted),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  AppButton(
                    '导出错误报告',
                    key: const ValueKey('export-error-report'),
                    icon: FIcons.download,
                    onPressed: working ? null : () => export(true),
                  ),
                  AppButton(
                    '导出游戏日志',
                    key: const ValueKey('export-game-log'),
                    icon: FIcons.fileText,
                    secondary: true,
                    onPressed: working ? null : () => export(false),
                  ),
                ],
              ),
              if (working)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: SelectableText(
                    message!,
                    style: TextStyle(
                      fontSize: 12,
                      color: failed ? Colors.red : c.accent,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          AppButton(
            '关闭',
            secondary: true,
            onPressed: working ? null : () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}
