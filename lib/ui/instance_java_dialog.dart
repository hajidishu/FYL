import 'scrolling.dart';
import '../l10n/app_localizations.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;

import '../core/controller.dart';
import '../core/java_discovery.dart';
import '../core/models.dart';
import 'java_installation_tile.dart';
import 'theme.dart';

class InstanceJavaDialog extends StatefulWidget {
  final LauncherController controller;
  final GameInstance instance;
  final JavaDiscovery? javaDiscovery;

  const InstanceJavaDialog({
    required this.controller,
    required this.instance,
    this.javaDiscovery,
    super.key,
  });

  @override
  State<InstanceJavaDialog> createState() => _InstanceJavaDialogState();
}

class _InstanceJavaDialogState extends State<InstanceJavaDialog> {
  late InstanceJavaMode mode = widget.instance.javaMode;
  late final path = TextEditingController(text: widget.instance.javaPath);
  late final discovery =
      widget.javaDiscovery ?? JavaDiscovery(widget.controller.platform);
  List<JavaInstallation> installations = [];
  JavaScanProgress progress = const JavaScanProgress(0, 0);
  bool scanning = false;
  bool scanned = false;
  bool saving = false;
  String? error;

  @override
  void dispose() {
    discovery.cancel();
    path.dispose();
    super.dispose();
  }

  Future<void> scan() async {
    setState(() {
      scanning = true;
      error = null;
      progress = const JavaScanProgress(0, 0);
    });
    try {
      final results = await discovery.discover(
        runtimeRoots: [
          widget.instance.root,
          widget.controller.settings.gameRoot,
          ...widget.controller.instances.map((instance) => instance.root),
        ],
        selectedJava: path.text.trim(),
        onProgress: (value) {
          if (mounted) setState(() => progress = value);
        },
      );
      if (mounted) {
        setState(() {
          installations = results;
          scanned = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '查找失败：$e');
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.controller.saveInstanceJava(
        widget.instance.id,
        mode,
        path.text,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  bool selected(JavaInstallation java) {
    String key(String value) => widget.controller.platform.os == 'windows'
        ? p.normalize(value).toLowerCase()
        : p.normalize(value);
    return mode == InstanceJavaMode.custom &&
        key(path.text.trim()) == key(java.executable);
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final instance = widget.instance;
    final executable = instance
        .withJava(mode, path.text)
        .javaExecutable(widget.controller.settings);
    return AlertDialog(
      title: const LText('版本 Java', style: TextStyle(fontSize: 19)),
      content: SizedBox(
        width: 520,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .65,
          ),
          child: AppScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LText(
                  '${instance.name} · 推荐 Java ${instance.javaMajor}',
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                SelectBox<InstanceJavaMode>(
                  key: const ValueKey('instance-java-mode'),
                  value: mode,
                  items: const {
                    InstanceJavaMode.inherit: '跟随默认 Java',
                    InstanceJavaMode.automatic: '自动选择 Java',
                    InstanceJavaMode.custom: '指定 Java',
                  },
                  onChanged: saving
                      ? null
                      : (value) => setState(() => mode = value),
                ),
                const SizedBox(height: 14),
                if (mode == InstanceJavaMode.custom) ...[
                  AppInput(
                    key: const ValueKey('instance-java-path'),
                    controller: path,
                    label: 'Java 可执行文件',
                    inlineLabel: true,
                    compact: true,
                    hint: widget.controller.platform.os == 'windows'
                        ? r'C:\Java\bin\java.exe'
                        : '/path/to/java/bin/java',
                    enabled: !saving,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: AppButton(
                      '选择文件',
                      icon: FIcons.folderOpen,
                      secondary: true,
                      small: true,
                      onPressed: saving
                          ? null
                          : () async {
                              final file = await openFile(
                                confirmButtonText: tr('选择 Java'),
                              );
                              if (file != null && mounted) {
                                setState(() => path.text = file.path);
                              }
                            },
                    ),
                  ),
                ] else
                  LText(
                    executable == 'java' ? '使用系统 Java' : executable,
                    style: TextStyle(color: c.muted, fontSize: 11),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    AppButton(
                      scanning
                          ? '正在查找…'
                          : scanned
                          ? '重新查找可用 Java'
                          : '自动查找可用 Java',
                      key: const ValueKey('instance-discover-java'),
                      icon: FIcons.search,
                      secondary: true,
                      small: true,
                      onPressed: scanning || saving ? null : scan,
                    ),
                    if (scanning)
                      AppButton(
                        '取消查找',
                        secondary: true,
                        small: true,
                        onPressed: discovery.cancel,
                      ),
                  ],
                ),
                if (scanning || scanned) ...[
                  const SizedBox(height: 12),
                  LText(
                    scanning
                        ? '已检查 ${progress.checked} 项，找到 ${progress.found} 个 Java'
                        : installations.isEmpty
                        ? '未找到 Java，可手动选择可执行文件。'
                        : '找到 ${installations.length} 个 Java',
                    style: TextStyle(color: c.muted, fontSize: 11),
                  ),
                ],
                if (installations.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: AppScrollView(
                      primary: false,
                      child: Column(
                        children: [
                          for (final java in installations)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: JavaInstallationTile(
                                installation: java,
                                platform: widget.controller.platform,
                                requiredMajor: instance.javaMajor,
                                selected: selected(java),
                                enabled: !scanning && !saving,
                                onSelected: () => setState(() {
                                  mode = InstanceJavaMode.custom;
                                  path.text = java.executable;
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 14),
                  LText(
                    error!,
                    style: TextStyle(color: Colors.red.shade400, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        AppButton(
          '取消',
          secondary: true,
          onPressed: saving ? null : () => Navigator.pop(context),
        ),
        AppButton(
          saving ? '正在保存…' : '保存',
          key: const ValueKey('save-instance-java'),
          onPressed: saving || scanning ? null : save,
        ),
      ],
    );
  }
}
