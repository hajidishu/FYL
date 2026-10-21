import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;
import '../core/controller.dart';
import '../core/local_mods.dart';
import '../core/models.dart';
import '../core/network.dart';
import 'theme.dart';

class InstanceMods extends StatefulWidget {
  final LauncherController controller;
  final GameInstance instance;
  final VoidCallback onDownload;
  const InstanceMods({
    required this.controller,
    required this.instance,
    required this.onDownload,
    super.key,
  });
  @override
  State<InstanceMods> createState() => _InstanceModsState();
}

class _InstanceModsState extends State<InstanceMods> {
  List<LocalMod> mods = [];
  Set<String> selected = {};
  String query = '', filter = 'all';
  String? error;
  bool loading = true, working = false;
  CancellationToken token = CancellationToken();
  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  @override
  void didUpdateWidget(InstanceMods old) {
    super.didUpdateWidget(old);
    if (old.instance.gameDirectory != widget.instance.gameDirectory) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    token.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (!mounted) return;
    token.cancel();
    token = CancellationToken();
    final request = token;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final results = await scanLocalMods(widget.instance, request);
      if (mounted && !request.cancelled) {
        setState(() {
          mods = results;
          selected = {};
        });
      }
    } on Cancelled {
      /* Superseded scan. */
    } catch (e) {
      if (mounted && !request.cancelled) setState(() => error = '$e');
    } finally {
      if (mounted && !request.cancelled) setState(() => loading = false);
    }
  }

  Future<void> run(Future<void> Function() operation) async {
    if (!mounted) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      await operation();
      if (!mounted) return;
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> installFiles() => run(() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Minecraft Mod', extensions: ['jar']),
      ],
    );
    if (files.isEmpty) return;
    final collisions = <String>[];
    for (final file in files) {
      if (await File(
        p.join(widget.instance.gameDirectory, 'mods', file.name),
      ).exists()) {
        collisions.add(file.name);
      }
    }
    var replace = false;
    if (collisions.isNotEmpty) {
      if (!mounted) return;
      replace =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('同名 Mod 已存在'),
              content: SizedBox(
                width: 430,
                child: SingleChildScrollView(
                  child: Text(collisions.join('\n')),
                ),
              ),
              actions: [
                AppButton(
                  '取消',
                  secondary: true,
                  onPressed: () => Navigator.pop(context, false),
                ),
                AppButton(
                  '替换文件',
                  onPressed: () => Navigator.pop(context, true),
                ),
              ],
            ),
          ) ??
          false;
      if (!replace) return;
    }
    await widget.controller.addLocalMods(
      widget.instance.id,
      files.map((f) => f.path).toList(),
      replace: replace,
    );
  });
  Future<void> removeSelected() async {
    final chosen = mods.where((m) => selected.contains(m.path)).toList();
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('移除 ${chosen.length} 个 Mod'),
            content: const Text('文件会移至版本文件夹的 .fyl/mod-trash，可手动恢复。'),
            actions: [
              AppButton(
                '取消',
                secondary: true,
                onPressed: () => Navigator.pop(context, false),
              ),
              AppButton('移除', onPressed: () => Navigator.pop(context, true)),
            ],
          ),
        ) ??
        false;
    if (confirmed && mounted) {
      await run(
        () => widget.controller.updateMods(
          widget.instance.id,
          chosen,
          remove: true,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final visible = mods
        .where(
          (m) =>
              m.matches(query) &&
              (filter == 'all' || m.enabled == (filter == 'enabled')),
        )
        .toList();
    final visiblePaths = visible.map((mod) => mod.path).toSet();
    final allVisibleSelected =
        visiblePaths.isNotEmpty && visiblePaths.every(selected.contains);
    final disabled =
        working ||
        loading ||
        widget.controller.installing ||
        widget.controller.preparingLaunch ||
        widget.controller.isGameDirectoryInUse(widget.instance.gameDirectory);
    final chosen = mods.where((m) => selected.contains(m.path)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppInput(
          hint: '搜索 Mod 名称、描述或文件名',
          onChanged: (v) => setState(() => query = v),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppButton(
              '打开文件夹',
              icon: FIcons.folderOpen,
              secondary: true,
              small: true,
              onPressed: () => widget.controller.openDirectory(
                p.join(widget.instance.gameDirectory, 'mods'),
              ),
            ),
            AppButton(
              '从文件安装',
              icon: FIcons.filePlus,
              secondary: true,
              small: true,
              onPressed: disabled ? null : installFiles,
            ),
            AppButton(
              '下载 Mod',
              icon: FIcons.download,
              small: true,
              onPressed: disabled ? null : widget.onDownload,
            ),
            AppButton(
              '刷新',
              icon: FIcons.refreshCw,
              secondary: true,
              small: true,
              onPressed: disabled ? null : refresh,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (key, label) in [
              ('all', '全部 (${mods.length})'),
              ('enabled', '已启用 (${mods.where((m) => m.enabled).length})'),
              ('disabled', '已禁用 (${mods.where((m) => !m.enabled).length})'),
            ])
              AppButton(
                label,
                small: true,
                secondary: filter != key,
                onPressed: () => setState(() => filter = key),
              ),
            AppButton(
              allVisibleSelected ? '取消选择' : '全选当前结果',
              key: const ValueKey('select-visible-mods'),
              small: true,
              secondary: true,
              onPressed: disabled
                  ? null
                  : () => setState(() {
                      if (allVisibleSelected) {
                        selected.removeAll(visiblePaths);
                      } else {
                        selected.addAll(visiblePaths);
                      }
                    }),
            ),
          ],
        ),
        if (selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '已选择 ${selected.length} 项',
                  style: TextStyle(color: c.muted, fontSize: 12),
                ),
                AppButton(
                  '启用',
                  small: true,
                  secondary: true,
                  onPressed: disabled
                      ? null
                      : () => run(
                          () => widget.controller.updateMods(
                            widget.instance.id,
                            chosen,
                            enabled: true,
                          ),
                        ),
                ),
                AppButton(
                  '禁用',
                  small: true,
                  secondary: true,
                  onPressed: disabled
                      ? null
                      : () => run(
                          () => widget.controller.updateMods(
                            widget.instance.id,
                            chosen,
                            enabled: false,
                          ),
                        ),
                ),
                AppButton(
                  '移除',
                  small: true,
                  secondary: true,
                  onPressed: disabled ? null : removeSelected,
                ),
              ],
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              style: TextStyle(
                color: c.dark ? Colors.red.shade200 : Colors.red.shade800,
                fontSize: 12,
              ),
            ),
          ),
        if (widget.controller.preparingLaunch ||
            widget.controller.isGameDirectoryInUse(
              widget.instance.gameDirectory,
            ))
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('请先关闭游戏再修改 Mod。', style: TextStyle(fontSize: 11)),
          ),
        if (loading || working)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    loading
                        ? '正在读取 Mod…'
                        : mods.isEmpty
                        ? '此版本还没有 Mod'
                        : '没有匹配的 Mod',
                    style: TextStyle(color: c.muted, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  itemCount: visible.length,
                  itemExtent: 116,
                  itemBuilder: (context, index) {
                    final mod = visible[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Surface(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Checkbox(
                              value: selected.contains(mod.path),
                              onChanged: disabled
                                  ? null
                                  : (v) => setState(() {
                                      if (v == true) {
                                        selected.add(mod.path);
                                      } else {
                                        selected.remove(mod.path);
                                      }
                                    }),
                            ),
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: mod.icon == null
                                  ? Icon(FIcons.box, size: 36, color: c.muted)
                                  : Image.memory(
                                      mod.icon!,
                                      fit: BoxFit.contain,
                                      cacheWidth:
                                          (48 *
                                                  MediaQuery.devicePixelRatioOf(
                                                    context,
                                                  ))
                                              .ceil(),
                                      filterQuality: FilterQuality.high,
                                      errorBuilder: (_, _, _) => Icon(
                                        FIcons.box,
                                        size: 36,
                                        color: c.muted,
                                      ),
                                    ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${mod.name}${mod.version.isEmpty ? '' : ' · ${mod.version}'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: mod.enabled
                                          ? c.foreground
                                          : c.muted,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    mod.warning ??
                                        (mod.description.isEmpty
                                            ? p.basename(mod.path)
                                            : mod.description.replaceAll(
                                                '\n',
                                                ' ',
                                              )),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: c.secondaryText,
                                      fontSize: 14,
                                      height: 1.5,
                                      letterSpacing: 0,
                                    ),
                                  ),
                                  Text(
                                    '${mod.loader.isEmpty ? '' : '${mod.loader} · '}${p.basename(mod.path)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: c.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Tooltip(
                              message: mod.enabled ? '禁用此 Mod' : '启用此 Mod',
                              child: Switch(
                                value: mod.enabled,
                                onChanged: disabled
                                    ? null
                                    : (v) => run(
                                        () => widget.controller.updateMods(
                                          widget.instance.id,
                                          [mod],
                                          enabled: v,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
