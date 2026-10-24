import 'scrolling.dart';
import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;
import '../core/community_models.dart';
import '../core/controller.dart';
import 'local_pack_import.dart';
import 'theme.dart';

class FileDropRegion extends StatefulWidget {
  final LauncherController controller;
  final Widget child;
  final VoidCallback onTaskStarted;
  final bool enabled;
  const FileDropRegion({
    required this.controller,
    required this.child,
    required this.onTaskStarted,
    this.enabled = true,
    super.key,
  });
  @override
  State<FileDropRegion> createState() => FileDropRegionState();
}

class FileDropRegionState extends State<FileDropRegion> {
  bool hovering = false, busy = false;
  bool get available =>
      widget.enabled &&
      !busy &&
      !widget.controller.installing &&
      !widget.controller.preparingLaunch &&
      ModalRoute.of(context)?.isCurrent != false;

  Future<void> handlePaths(List<String> paths) =>
      handleFiles(paths.map(DropItemFile.new).toList());

  Future<void> handleFiles(List<DropItem> files) async {
    if (!available || files.isEmpty) return;
    setState(() {
      busy = true;
      hovering = false;
    });
    final bookmarks = <Uint8List>[];
    final controller = widget.controller;
    controller.dismissMessage();
    try {
      if (Platform.isMacOS) {
        for (final file in files) {
          final bookmark = file.extraAppleBookmark;
          if (bookmark != null &&
              bookmark.isNotEmpty &&
              await DesktopDrop.instance.startAccessingSecurityScopedResource(
                bookmark: bookmark,
              )) {
            bookmarks.add(bookmark);
          }
        }
      }
      final paths = <String>[];
      for (final file in files) {
        final path = file.path;
        if (await FileSystemEntity.type(path, followLinks: false) !=
                FileSystemEntityType.file ||
            ![
              '.jar',
              '.mrpack',
              '.zip',
            ].contains(p.extension(path).toLowerCase())) {
          throw const FormatException('支持拖入 JAR 格式的 Mod、MRPACK 或 ZIP 格式的整合包。');
        }
        if (!paths.contains(path)) paths.add(path);
      }
      if (!mounted) return;
      final mods = paths
          .where((path) => p.extension(path).toLowerCase() == '.jar')
          .toList();
      if (mods.isNotEmpty) {
        final choices = await showDialog<ModImportChoices>(
          context: context,
          builder: (_) => ModImportDialog(controller: controller, files: mods),
        );
        if (choices != null && mounted) {
          await controller.addLocalMods(
            choices.instanceId,
            mods,
            replace: choices.replace,
          );
          final name =
              controller.instances
                  .where((instance) => instance.id == choices.instanceId)
                  .firstOrNull
                  ?.name ??
              '';
          controller.notice = '已将 ${mods.length} 个 Mod 安装到 $name';
          controller.notifyListeners();
        }
      }
      for (final path in paths.where(
        (path) => p.extension(path).toLowerCase() != '.jar',
      )) {
        if (!mounted) return;
        await importLocalPack(
          context,
          controller,
          path,
          onStarted: widget.onTaskStarted,
        );
      }
    } catch (error) {
      controller.errorMessage =
          '导入失败：${error is StateError
              ? error.message
              : error is FormatException
              ? error.message
              : error}';
      controller.notifyListeners();
    } finally {
      for (final bookmark in bookmarks) {
        try {
          await DesktopDrop.instance.stopAccessingSecurityScopedResource(
            bookmark: bookmark,
          );
        } catch (_) {
          /* The native window may already have closed. */
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return DropTarget(
      enable: available,
      onDragEntered: (_) => setState(() => hovering = true),
      onDragExited: (_) => setState(() => hovering = false),
      onDragDone: (details) => unawaited(handleFiles(details.files)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (hovering && available)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: c.background.withValues(alpha: .94),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: c.accent, width: 2),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(FIcons.packagePlus, size: 42, color: c.accent),
                      const SizedBox(height: 16),
                      const LText(
                        '松开以安装 Mod 或整合包',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ModImportChoices {
  final String instanceId;
  final bool replace;
  const ModImportChoices(this.instanceId, this.replace);
}

class ModImportDialog extends StatefulWidget {
  final LauncherController controller;
  final List<String> files;
  const ModImportDialog({
    required this.controller,
    required this.files,
    super.key,
  });
  @override
  State<ModImportDialog> createState() => _ModImportDialogState();
}

class _ModImportDialogState extends State<ModImportDialog> {
  late String? selected = widget.controller.selectedInstance?.id;
  bool replace = false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final instance = controller.instances
          .where((instance) => instance.id == selected)
          .firstOrNull;
      final error = instance == null
          ? '请先安装一个游戏版本。'
          : instanceModLoader(instance) == null
          ? '此版本没有 Mod 加载器，请选择已安装加载器的版本。'
          : controller.isGameDirectoryInUse(instance.gameDirectory)
          ? '请先关闭使用此版本目录的游戏。'
          : null;
      return AlertDialog(
        scrollable: true,
        title: const LText('安装 Mod'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LText(
                '选择目标版本 · ${widget.files.length} 个文件',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 10),
              if (controller.instances.isNotEmpty)
                SelectBox<String>(
                  localizeItems: false,
                  value: selected ?? controller.instances.first.id,
                  items: {
                    for (final instance in controller.instances)
                      instance.id: '${instance.name} · ${instance.version}',
                  },
                  onChanged: (value) => setState(() => selected = value),
                ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: AppScrollView(
                  child: Text(
                    widget.files.map(p.basename).join('\n'),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: LauncherColors.of(context).secondaryText,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              CheckboxListTile(
                value: replace,
                onChanged: (value) => setState(() => replace = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const LText(
                  '覆盖同名 Mod 文件',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              if (error != null)
                LText(
                  error,
                  style: TextStyle(
                    fontSize: 13,
                    color: LauncherColors.of(context).secondaryText,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          AppButton(
            '取消',
            secondary: true,
            onPressed: () => Navigator.pop(context),
          ),
          AppButton(
            '安装',
            key: const ValueKey('confirm-dropped-mods'),
            onPressed: error != null
                ? null
                : () => Navigator.pop(
                    context,
                    ModImportChoices(selected!, replace),
                  ),
          ),
        ],
      );
    },
  );
}
