import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/controller.dart';
import '../core/install_options.dart';
import '../core/mod_catalog.dart';
import '../core/models.dart';
import '../core/network.dart';
import 'theme.dart';
import 'component_icon.dart';

class InstallPage extends StatefulWidget {
  final LauncherController controller;
  final MinecraftVersion version;
  final VoidCallback onBack;
  final void Function(String name, InstallOptions options) onInstall;
  final ModCatalog? catalog;
  const InstallPage({
    required this.controller,
    required this.version,
    required this.onBack,
    required this.onInstall,
    this.catalog,
    super.key,
  });
  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  late final name = TextEditingController(text: widget.version.id);
  late final network = OfficialNetwork(widget.controller.settings.copy());
  late final catalog = widget.catalog ?? ModCatalog(network);
  final token = CancellationToken();
  final versions = <ModLoader, List<LoaderVersion>>{};
  List<OptiFineVersion> optifineVersions = [];
  List<CompatibilityMod> optifabricVersions = [];
  final loading = <String>{};
  final failures = <String, String>{};
  final expanded = <String>{};
  LoaderVersion? loader;
  OptiFineVersion? optifine;
  CompatibilityMod? optifabric;
  String? formError;
  late String suggested = widget.version.id;
  InstallOptions get options => InstallOptions(
    loader: loader,
    optifine: optifine,
    optifabric: optifabric,
  );

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    token.cancel();
    network.close();
    name.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (loading.isNotEmpty) return;
    setState(() {
      failures.clear();
      loading.addAll(['forge', 'neoforge', 'fabric', 'optifine', 'optifabric']);
    });
    Future<void> fetch<T>(
      String key,
      Future<T> request,
      void Function(T) assign,
    ) async {
      try {
        final value = await request;
        if (mounted) setState(() => assign(value));
      } catch (e) {
        if (mounted && !token.cancelled) setState(() => failures[key] = '$e');
      } finally {
        if (mounted) setState(() => loading.remove(key));
      }
    }

    await Future.wait([
      for (final kind in ModLoader.values)
        fetch(
          kind.name,
          catalog.loaders(kind, widget.version.id, token),
          (value) => versions[kind] = value,
        ),
      fetch(
        'optifine',
        catalog.optifine(widget.version.id, token),
        (value) => optifineVersions = value,
      ),
      fetch(
        'optifabric',
        catalog.optifabric(widget.version.id, token),
        (value) => optifabricVersions = value,
      ),
    ]);
  }

  void selectionChanged() {
    final next =
        '${widget.version.id}${options.isVanilla ? '' : '-${loader?.loader.label ?? 'OptiFine'}'}';
    if (name.text == suggested) name.text = next;
    suggested = next;
    formError = null;
  }

  Future<void> localOptifine() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JAR', extensions: ['jar']),
      ],
    );
    if (file == null || !mounted) return;
    final fileName = p.basename(file.path);
    if (!fileName.contains('OptiFine_${widget.version.id}_')) {
      setState(
        () => formError =
            '请选择适用于 Minecraft ${widget.version.id} 的 OptiFine 官方 JAR。',
      );
      return;
    }
    setState(() {
      optifine = OptiFineVersion(fileName, localPath: file.path);
      selectionChanged();
    });
  }

  Future<void> localOptifabric() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'JAR', extensions: ['jar']),
      ],
    );
    if (file == null || !mounted) return;
    try {
      final archive = ZipDecoder().decodeBytes(
        await File(file.path).readAsBytes(),
      );
      final entry = archive.findFile('fabric.mod.json');
      final descriptor = entry == null
          ? null
          : jsonDecode(utf8.decode(entry.content)) as Json;
      if (descriptor?['id'] != 'optifabric') {
        throw const FormatException('该文件不是 OptiFabric 兼容模组。');
      }
      if (!mounted) return;
      setState(() {
        optifabric = CompatibilityMod(
          version: descriptor!['version'].toString(),
          fileName: p.basename(file.path),
          url: '',
          localPath: file.path,
        );
        selectionChanged();
      });
    } catch (e) {
      if (mounted) setState(() => formError = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final invalid = options.validationError;
    return Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: widget.onBack,
                tooltip: '返回版本列表',
                icon: Icon(FIcons.arrowLeft, color: c.muted, size: 19),
              ),
              const SizedBox(width: 8),
              const ComponentIcon(GameComponent.minecraft, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '安装 Minecraft ${widget.version.id}',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: loading.isEmpty ? load : null,
                tooltip: '刷新组件版本',
                icon: const Icon(FIcons.refreshCw, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AppInput(
                    controller: name,
                    label: '版本名称',
                    description: '同时作为 versions 下的文件夹名称。',
                  ),
                  const SizedBox(height: 18),
                  Text(
                    '可选组件',
                    style: TextStyle(color: c.muted, fontSize: 11, height: 1.7),
                  ),
                  const SizedBox(height: 15),
                  for (final kind in ModLoader.values) ...[
                    _section(
                      kind.name,
                      kind.label,
                      selected: loader?.loader == kind ? loader!.version : null,
                      count: versions[kind]?.length ?? 0,
                      note: loader != null && loader!.loader != kind
                          ? '选择后替换 ${loader!.loader.label}'
                          : null,
                      clear: () => setState(() {
                        loader = null;
                        optifabric = null;
                        selectionChanged();
                      }),
                      rows: [
                        for (final version
                            in versions[kind] ?? <LoaderVersion>[])
                          _choice(
                            version.version,
                            component: componentFor(kind.label),
                            selected:
                                loader?.loader == kind &&
                                loader?.version == version.version,
                            note: version.stable ? null : '预发布',
                            onTap: () => setState(() {
                              loader = version;
                              if (kind != ModLoader.fabric) optifabric = null;
                              selectionChanged();
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  _section(
                    'optifine',
                    'OptiFine',
                    selected: optifine?.label,
                    count: optifineVersions.length,
                    clear: () => setState(() {
                      optifine = null;
                      optifabric = null;
                      selectionChanged();
                    }),
                    rows: [
                      for (final version in optifineVersions)
                        _choice(
                          version.label,
                          component: GameComponent.optifine,
                          selected: optifine?.fileName == version.fileName,
                          onTap: () => setState(() {
                            optifine = version;
                            selectionChanged();
                          }),
                        ),
                    ],
                    footer: AppButton(
                      '选择本地 OptiFine JAR',
                      icon: FIcons.folderOpen,
                      secondary: true,
                      small: true,
                      onPressed: localOptifine,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _section(
                    'optifabric',
                    'OptiFabric',
                    selected: optifabric?.version,
                    count: optifabricVersions.length,
                    enabled: options.fabricOptifine,
                    note: options.fabricOptifine
                        ? 'Fabric 与 OptiFine 的兼容模组'
                        : '需要先选择 Fabric 与 OptiFine',
                    clear: () => setState(() {
                      optifabric = null;
                      selectionChanged();
                    }),
                    rows: [
                      for (final version in optifabricVersions)
                        _choice(
                          version.version,
                          component: GameComponent.optifabric,
                          selected: optifabric?.version == version.version,
                          onTap: () => setState(() {
                            optifabric = version;
                            selectionChanged();
                          }),
                        ),
                    ],
                    footer: AppButton(
                      '选择本地 OptiFabric JAR',
                      icon: FIcons.folderOpen,
                      secondary: true,
                      small: true,
                      onPressed: options.fabricOptifine
                          ? localOptifabric
                          : null,
                    ),
                  ),
                  if (options.fabricOptifine) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFC48A27).withValues(alpha: .13),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Fabric 与 OptiFine 存在兼容性问题',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '即使安装 OptiFabric，也可能与其他模组冲突。建议使用 Iris 替代 OptiFine；若继续此组合，请在上方选择对应的 OptiFabric。',
                            style: TextStyle(fontSize: 12, height: 1.7),
                          ),
                          const SizedBox(height: 10),
                          AppButton(
                            '了解 Iris',
                            secondary: true,
                            small: true,
                            onPressed: () => launchUrl(
                              Uri.parse('https://irisshaders.dev/'),
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    '安装目录：${widget.controller.settings.gameRoot}',
                    style: TextStyle(color: c.muted, fontSize: 11, height: 1.8),
                  ),
                  const SizedBox(height: 18),
                ],
              ),
            ),
          ),
          if (formError != null || invalid != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                formError ?? invalid!,
                style: TextStyle(
                  fontSize: 12,
                  color: c.dark
                      ? const Color(0xFFEFBD75)
                      : const Color(0xFF925614),
                ),
              ),
            ),
          const SizedBox(height: 12),
          FButton(
            prefix: const Icon(FIcons.download, size: 16),
            onPress: widget.controller.installing || invalid != null
                ? null
                : () {
                    final error = validateVersionName(name.text.trim());
                    if (error != null) {
                      setState(() => formError = error);
                      return;
                    }
                    if (Directory(
                      p.join(
                        widget.controller.settings.gameRoot,
                        'versions',
                        name.text.trim(),
                      ),
                    ).existsSync()) {
                      setState(() => formError = '版本名称已存在，请使用其他名称。');
                      return;
                    }
                    widget.onInstall(name.text.trim(), options);
                  },
            child: const Text('开始安装'),
          ),
        ],
      ),
    );
  }

  Widget _section(
    String key,
    String title, {
    required String? selected,
    required int count,
    required VoidCallback clear,
    required List<Widget> rows,
    String? note,
    Widget? footer,
    bool enabled = true,
  }) {
    final c = LauncherColors.of(context);
    final open = expanded.contains(key);
    final status =
        selected ??
        (loading.contains(key)
            ? '正在读取版本…'
            : failures.containsKey(key)
            ? '读取失败，可刷新重试'
            : count == 0
            ? '无兼容版本'
            : '$count 个可选版本');
    return Surface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: enabled
                ? () => setState(() {
                    if (open) {
                      expanded.remove(key);
                    } else {
                      expanded.add(key);
                    }
                  })
                : null,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(
                children: [
                  ComponentIcon(componentFor(title), size: 40),
                  const SizedBox(width: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Text(
                      enabled ? status : note ?? status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: selected == null ? c.muted : c.accent,
                      ),
                    ),
                  ),
                  if (selected != null)
                    IconButton(
                      tooltip: '取消选择 $title',
                      onPressed: clear,
                      icon: const Icon(FIcons.x, size: 14),
                      visualDensity: VisualDensity.compact,
                    ),
                  Icon(
                    open && enabled ? FIcons.chevronUp : FIcons.chevronDown,
                    size: 15,
                    color: c.muted,
                  ),
                ],
              ),
            ),
          ),
          if (open && enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (note != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        note,
                        style: TextStyle(color: c.muted, fontSize: 11),
                      ),
                    ),
                  if (loading.contains(key))
                    const LinearProgressIndicator(minHeight: 2)
                  else if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        failures[key] ?? '当前 Minecraft 版本暂无可用的 $title。',
                        style: TextStyle(color: c.muted, fontSize: 11),
                      ),
                    ),
                  if (rows.isNotEmpty) ...[
                    Text(
                      '最新版本',
                      style: TextStyle(color: c.muted, fontSize: 11),
                    ),
                    const SizedBox(height: 6),
                    rows.first,
                    const SizedBox(height: 14),
                    Text(
                      '全部版本 (${rows.length})',
                      style: TextStyle(color: c.muted, fontSize: 11),
                    ),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 250),
                      child: SingleChildScrollView(
                        primary: false,
                        child: Column(children: rows),
                      ),
                    ),
                  ],
                  if (footer != null) ...[
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerLeft, child: footer),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _choice(
    String text, {
    required GameComponent component,
    required bool selected,
    required VoidCallback onTap,
    String? note,
  }) {
    final c = LauncherColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.accentBackground : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            ComponentIcon(component, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            if (note != null) Tag(note),
            if (selected) ...[
              const SizedBox(width: 10),
              Icon(FIcons.circleCheck, size: 15, color: c.accent),
            ],
          ],
        ),
      ),
    );
  }
}
