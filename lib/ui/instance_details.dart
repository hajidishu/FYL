import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;
import '../core/accounts.dart';
import '../core/community_models.dart';
import '../core/controller.dart';
import '../core/instance_tools.dart';
import '../core/minecraft.dart';
import '../core/models.dart';
import 'community_page.dart';
import 'instance_icon.dart';
import 'instance_java_dialog.dart';
import 'instance_mods.dart';
import 'theme.dart';
import 'memory_preview.dart';

class InstanceDetailsPage extends StatefulWidget {
  final LauncherController controller;
  final String instanceId;
  final VoidCallback onBack;
  final ValueChanged<bool> onDirty;
  final ValueChanged<int> navigate;
  const InstanceDetailsPage({
    required this.controller,
    required this.instanceId,
    required this.onBack,
    required this.onDirty,
    required this.navigate,
    super.key,
  });
  @override
  State<InstanceDetailsPage> createState() => _InstanceDetailsPageState();
}

class _InstanceDetailsPageState extends State<InstanceDetailsPage> {
  final fields = <String, TextEditingController>{};
  final overrideDrafts = <String, String>{};
  int tab = 0, exported = 0, exportTotal = 0;
  bool dirty = false, busy = false, browseMods = false;
  bool ownMemory = false,
      ownWindow = false,
      ownJvm = false,
      ownGame = false,
      ownHook = false;
  bool fullscreen = false,
      favorite = false,
      skipJava = false,
      gameOptions = true;
  bool automaticMemory = true;
  int minimize = -1, verify = -1;
  String icon = 'auto';
  String? error, message;
  Set<String> folders = {...exportDefaults};
  GameInstance get instance =>
      widget.controller.instances.firstWhere((i) => i.id == widget.instanceId);
  @override
  void initState() {
    super.initState();
    final i = instance;
    final s = i.launchSettings;
    final effective = i.effectiveSettings(widget.controller.settings);
    ownMemory =
        s.automaticMemory != null || s.minMemory != null || s.maxMemory != null;
    automaticMemory = effective.automaticMemory;
    ownWindow = s.width != null || s.height != null || s.fullscreen != null;
    ownJvm = s.jvmArguments != null;
    ownGame = s.gameArguments != null;
    ownHook = s.preLaunchCommand != null;
    fullscreen = effective.fullscreen;
    favorite = i.favorite;
    icon = i.icon;
    skipJava = s.skipJavaVersionCheck;
    minimize = s.minimizeOnLaunch == null
        ? -1
        : s.minimizeOnLaunch!
        ? 1
        : 0;
    verify = s.verifyDownloads == null
        ? -1
        : s.verifyDownloads!
        ? 1
        : 0;
    final initial = <String, String>{
      'name': i.name,
      'description': i.description,
      'category': i.category,
      'minMemory': effective.minMemory == 0 ? '' : '${effective.minMemory}',
      'maxMemory': '${effective.maxMemory}',
      'autoMemoryLimit': '${effective.autoMemoryLimit}',
      'width': '${effective.width}',
      'height': '${effective.height}',
      'jvmArguments': effective.jvmArguments,
      'gameArguments': effective.gameArguments,
      'preLaunchCommand': effective.preLaunchCommand,
      'packVersion': '1.0.0',
    };
    for (final entry in initial.entries) {
      fields[entry.key] = TextEditingController(text: entry.value);
    }
  }

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  void changed() {
    setState(() {
      dirty = true;
      error = null;
    });
    widget.onDirty(true);
  }

  String inheritedValue(String key) {
    final defaults = widget.controller.settings;
    return switch (key) {
      'minMemory' => defaults.minMemory == 0 ? '' : '${defaults.minMemory}',
      'maxMemory' => '${defaults.maxMemory}',
      'autoMemoryLimit' => '${defaults.autoMemoryLimit}',
      'width' => '${defaults.width}',
      'height' => '${defaults.height}',
      'jvmArguments' => defaults.jvmArguments,
      'gameArguments' => defaults.gameArguments,
      'preLaunchCommand' => defaults.preLaunchCommand,
      _ => fields[key]!.text,
    };
  }

  void setOverride(bool enabled, bool current, List<String> keys) {
    if (enabled == current) return;
    for (final key in keys) {
      if (enabled) {
        fields[key]!.text = overrideDrafts[key] ?? inheritedValue(key);
      } else {
        overrideDrafts[key] = fields[key]!.text;
        fields[key]!.text = inheritedValue(key);
      }
    }
  }

  LauncherSettings memoryDraft() {
    final draft = widget.controller.settings.copy();
    if (ownJvm) draft.jvmArguments = fields['jvmArguments']!.text.trim();
    if (ownMemory) {
      draft.automaticMemory = automaticMemory;
      draft.minMemory = fields['minMemory']!.text.trim().isEmpty
          ? 0
          : int.tryParse(fields['minMemory']!.text) ?? -1;
      draft.maxMemory = int.tryParse(fields['maxMemory']!.text) ?? -1;
      draft.autoMemoryLimit =
          int.tryParse(fields['autoMemoryLimit']!.text) ?? -1;
    }
    return draft;
  }

  void resetLaunchOverrides() {
    setOverride(false, ownMemory, const [
      'minMemory',
      'maxMemory',
      'autoMemoryLimit',
    ]);
    automaticMemory = widget.controller.settings.automaticMemory;
    setOverride(false, ownWindow, const ['width', 'height']);
    setOverride(false, ownJvm, const ['jvmArguments']);
    setOverride(false, ownGame, const ['gameArguments']);
    setOverride(false, ownHook, const ['preLaunchCommand']);
    overrideDrafts.clear();
    ownMemory = ownWindow = ownJvm = ownGame = ownHook = false;
    fullscreen = widget.controller.settings.fullscreen;
    skipJava = false;
    minimize = verify = -1;
    changed();
  }

  Future<bool> confirm(String title, String body, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            AppButton(
              '取消',
              secondary: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            AppButton(action, onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      ) ??
      false;
  Future<void> back() async {
    if (dirty && !await confirm('有尚未保存的修改', '离开后会放弃本次修改。', '放弃修改')) return;
    if (!mounted) return;
    widget.onDirty(false);
    widget.onBack();
  }

  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => error = '$e'.replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> repair() async {
    if (dirty) {
      setState(() => error = '请先保存修改。');
      return;
    }
    setState(() {
      error = null;
      message = null;
    });
    try {
      await widget.controller.repairInstance(instance.id);
      if (mounted) setState(() => message = widget.controller.notice);
    } catch (failure) {
      if (mounted) {
        setState(() => error = '$failure'.replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> save() => run(() async {
    int number(String key) => int.tryParse(fields[key]!.text.trim()) ?? -1;
    await widget.controller.saveInstance(
      instance.copyWith(
        name: fields['name']!.text.trim(),
        description: fields['description']!.text.trim(),
        category: fields['category']!.text.trim(),
        icon: icon,
        favorite: favorite,
        launchSettings: InstanceLaunchSettings(
          automaticMemory: ownMemory ? automaticMemory : null,
          autoMemoryLimit: ownMemory ? number('autoMemoryLimit') : null,
          minMemory: ownMemory
              ? fields['minMemory']!.text.trim().isEmpty
                    ? 0
                    : number('minMemory')
              : null,
          maxMemory: ownMemory ? number('maxMemory') : null,
          width: ownWindow ? number('width') : null,
          height: ownWindow ? number('height') : null,
          fullscreen: ownWindow ? fullscreen : null,
          jvmArguments: ownJvm ? fields['jvmArguments']!.text.trim() : null,
          gameArguments: ownGame ? fields['gameArguments']!.text.trim() : null,
          preLaunchCommand: ownHook
              ? fields['preLaunchCommand']!.text.trim()
              : null,
          minimizeOnLaunch: minimize == -1 ? null : minimize == 1,
          verifyDownloads: verify == -1 ? null : verify == 1,
          skipJavaVersionCheck: skipJava,
        ),
      ),
    );
    if (mounted) {
      setState(() {
        dirty = false;
        message = '版本设置已保存';
      });
      widget.onDirty(false);
    }
  });
  Future<void> chooseIcon() => run(() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '图片', extensions: ['png', 'jpg', 'jpeg', 'webp']),
      ],
    );
    if (file == null) return;
    if (await file.length() > 8 * 1024 * 1024) {
      throw ArgumentError('请选择小于 8 MB 的图片。');
    }
    final codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: 512,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final bytes = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        final path = p.join(
          widget.controller.supportDirectory,
          'instance-icons',
          '${DateTime.now().microsecondsSinceEpoch}.png',
        );
        await File(path).parent.create(recursive: true);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
        if (mounted) {
          icon = path;
          changed();
        }
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });
  Future<void> isolation() async {
    var isolated = instance.isolated;
    var copyData = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('版本隔离'),
          content: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectBox<bool>(
                  value: isolated,
                  items: const {true: '开启：使用版本文件夹', false: '关闭：使用游戏根目录'},
                  onChanged: (v) => update(() => isolated = v),
                ),
                const SizedBox(height: 14),
                Text(
                  instance.copyWith(isolated: isolated).gameDirectory,
                  style: const TextStyle(fontSize: 11),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    '同时复制当前游戏数据',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    '原文件保留；不同的同名文件不会覆盖。版本 JSON、JAR 和共享依赖不参与复制。',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: copyData,
                  onChanged: (v) => update(() => copyData = v ?? true),
                ),
              ],
            ),
          ),
          actions: [
            AppButton(
              '取消',
              secondary: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            AppButton('切换目录', onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      await run(
        () => widget.controller.changeInstanceIsolation(
          instance.id,
          isolated,
          copyData: copyData,
        ),
      );
    }
  }

  Future<void> remove() async {
    var moveData = true;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('移除游戏版本'),
          content: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('从版本列表移除“${instance.name}”。'),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    '同时移走版本文件夹',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    instance.isolated
                        ? '包含此版本的存档和 Mod。移至 .fyl-trash，可手动恢复。'
                        : '游戏根目录中的共享存档和 Mod 会保留。版本文件夹移至 .fyl-trash，可手动恢复。',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: moveData,
                  onChanged: (v) => update(() => moveData = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            AppButton(
              '取消',
              secondary: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            AppButton('移除版本', onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      await run(() async {
        await widget.controller.removeInstance(instance.id, moveData: moveData);
        if (mounted) {
          widget.onDirty(false);
          widget.onBack();
        }
      });
    }
  }

  Future<void> exportScript() => run(() async {
    if (dirty) throw StateError('请先保存修改。');
    widget.controller.editableInstance(instance.id);
    final settings = instance.effectiveSettings(widget.controller.settings);
    final account = widget.controller.activeAccount;
    if (account == null) throw StateError('请先添加一个账号，以确定离线启动用户名。');
    final command = await MinecraftRunner(widget.controller.platform).prepare(
      instance,
      settings,
      session: GameSession(username: account.username, uuid: account.uuid),
    );
    final windows = widget.controller.platform.os == 'windows';
    final location = await getSaveLocation(
      suggestedName: '${fileName(instance.name)}.${windows ? 'ps1' : 'sh'}',
      acceptedTypeGroups: [
        XTypeGroup(label: '启动脚本', extensions: [windows ? 'ps1' : 'sh']),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(
      launchScript(
        command,
        widget.controller.platform,
        preLaunchCommand: settings.preLaunchCommand,
      ),
    );
    if (!windows) await Process.run('chmod', ['+x', location.path]);
    if (mounted) setState(() => message = '离线启动脚本已保存：${location.path}');
  });
  Future<void> exportPack() => run(() async {
    if (dirty) throw StateError('请先保存修改。');
    final location = await getSaveLocation(
      suggestedName: '${fileName(instance.name)}.mrpack',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Modrinth 整合包', extensions: ['mrpack']),
      ],
    );
    if (location == null) return;
    final count = await widget.controller.exportPack(
      instance.id,
      location.path.toLowerCase().endsWith('.mrpack')
          ? location.path
          : '${location.path}.mrpack',
      folders: folders,
      version: fields['packVersion']!.text,
      gameOptions: gameOptions,
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            exported = done;
            exportTotal = total;
          });
        }
      },
    );
    if (mounted) setState(() => message = '已导出 $count 个文件：${location.path}');
  });
  String fileName(String input) =>
      input.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.instances.any((i) => i.id == widget.instanceId)) {
      return const SizedBox.shrink();
    }
    final c = LauncherColors.of(context);
    final i = instance;
    final operationActive = widget.controller.instanceOperation != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '返回版本列表',
                onPressed: busy ? null : back,
                icon: const Icon(FIcons.arrowLeft, size: 20),
              ),
              const SizedBox(width: 10),
              InstanceIcon(i, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      i.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${i.version} · ${i.components.isEmpty ? '原版' : i.components}',
                      style: TextStyle(color: c.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              AppButton(
                busy
                    ? '处理中…'
                    : operationActive
                    ? '其他任务处理中'
                    : dirty
                    ? '保存修改'
                    : '已保存',
                key: const ValueKey('save-instance-settings'),
                icon: FIcons.check,
                small: true,
                onPressed: dirty && !busy && !operationActive ? save : null,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (index, label) in [
                '概览',
                '启动设置',
                'Mod 管理',
                '导出',
              ].indexed)
                AppButton(
                  label,
                  key: ValueKey('instance-tab-$index'),
                  small: true,
                  secondary: tab != index,
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          tab = index;
                          browseMods = false;
                        }),
                ),
            ],
          ),
          if (error != null || message != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: SelectableText(
                error ?? message!,
                style: TextStyle(
                  fontSize: 12,
                  color: error == null
                      ? c.accent
                      : c.dark
                      ? Colors.red.shade200
                      : Colors.red.shade800,
                ),
              ),
            ),
          if (busy || widget.controller.repairingInstanceId == i.id)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      minHeight: 3,
                      value: widget.controller.repairingInstanceId == i.id
                          ? widget.controller.repairTask?.progress
                          : exportTotal > 0
                          ? exported / exportTotal
                          : null,
                    ),
                  ),
                  if (widget.controller.instanceOperation != null)
                    TextButton(
                      onPressed: widget.controller.cancelInstall,
                      child: const Text('取消任务'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          Expanded(
            child: tab == 2
                ? _mods()
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (tab == 0)
                          ...overview()
                        else if (tab == 1)
                          ...settings()
                        else
                          ...export(),
                        const SizedBox(height: 26),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Surface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    ),
  );
  Widget field(
    String key,
    String label, {
    bool enabled = true,
    int lines = 1,
    String? description,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: AppInput(
      key: ValueKey('instance-field-$key'),
      controller: fields[key],
      compact: true,
      label: label,
      maxLines: lines,
      description: description,
      enabled: enabled && !busy,
      onChanged: (_) {
        if (key != 'packVersion') changed();
      },
    ),
  );
  Widget check(
    String title,
    bool value,
    ValueChanged<bool> callback, {
    String? subtitle,
    Key? key,
  }) => CheckboxListTile(
    key: key,
    contentPadding: EdgeInsets.zero,
    dense: true,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    minVerticalPadding: 4,
    horizontalTitleGap: 8,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: subtitle == null
        ? null
        : Text(subtitle, style: const TextStyle(fontSize: 12)),
    value: value,
    onChanged: busy
        ? null
        : (v) {
            callback(v ?? false);
            changed();
          },
  );
  Widget pair(Widget a, Widget b) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: a),
      const SizedBox(width: 14),
      Expanded(child: b),
    ],
  );
  List<Widget> overview() => [
    section('个性化', [
      field('name', '版本名称'),
      field('description', '描述', lines: 2),
      field('category', '版本标签', description: '留空时自动显示加载器或版本类型。'),
      Text(
        '版本图标',
        style: TextStyle(color: LauncherColors.of(context).muted, fontSize: 12),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          InstanceIcon(instance.copyWith(icon: icon), size: 48),
          const SizedBox(width: 14),
          Expanded(
            child: SelectBox<String>(
              value:
                  [
                    'auto',
                    'minecraft',
                    'forge',
                    'neoforge',
                    'fabric',
                    'quilt',
                    'optifine',
                    'optifabric',
                  ].contains(icon)
                  ? icon
                  : 'custom',
              items: {
                'auto': '自动',
                'minecraft': '原版（草方块）',
                'forge': 'Forge（铁砧）',
                'neoforge': 'NeoForge（狐狸）',
                'fabric': 'Fabric',
                'quilt': 'Quilt',
                'optifine': 'OptiFine',
                'optifabric': 'OptiFabric',
                if (![
                  'auto',
                  'minecraft',
                  'forge',
                  'neoforge',
                  'fabric',
                  'quilt',
                  'optifine',
                  'optifabric',
                ].contains(icon))
                  'custom': '自定义图片',
              },
              onChanged: busy
                  ? null
                  : (v) {
                      icon = v;
                      changed();
                    },
            ),
          ),
          const SizedBox(width: 10),
          AppButton(
            '选择图片',
            secondary: true,
            small: true,
            onPressed: busy ? null : chooseIcon,
          ),
        ],
      ),
      check('收藏此版本', favorite, (v) => favorite = v),
    ]),
    section('游戏文件', [
      SelectableText(
        instance.gameDirectory,
        style: TextStyle(fontSize: 11, color: LauncherColors.of(context).muted),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          AppButton(
            '版本文件夹',
            secondary: true,
            small: true,
            icon: FIcons.folderOpen,
            onPressed: () =>
                widget.controller.openDirectory(instance.versionDirectory),
          ),
          for (final (label, relative) in [
            ('游戏目录', ''),
            ('存档', 'saves'),
            ('Mod', 'mods'),
            ('资源包', 'resourcepacks'),
            ('光影包', 'shaderpacks'),
          ])
            AppButton(
              label,
              secondary: true,
              small: true,
              icon: FIcons.folderOpen,
              onPressed: () => widget.controller.openDirectory(
                p.join(instance.gameDirectory, relative),
              ),
            ),
          AppButton(
            '版本隔离',
            secondary: true,
            small: true,
            onPressed: busy || widget.controller.installing ? null : isolation,
          ),
        ],
      ),
    ]),
    section('管理', [
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          AppButton(
            widget.controller.repairingInstanceId == instance.id
                ? '正在修复…'
                : '补全与修复文件',
            icon: FIcons.refreshCw,
            secondary: true,
            small: true,
            onPressed: busy || widget.controller.installing ? null : repair,
          ),
          AppButton(
            '导出离线启动脚本',
            icon: FIcons.terminal,
            secondary: true,
            small: true,
            onPressed: busy ? null : exportScript,
          ),
          AppButton(
            '移除版本',
            icon: FIcons.trash2,
            secondary: true,
            small: true,
            onPressed: busy || widget.controller.installing ? null : remove,
          ),
        ],
      ),
    ]),
  ];
  List<Widget> settings() => [
    section('Java', [
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(switch (instance.javaMode) {
                  InstanceJavaMode.inherit => '跟随默认 Java',
                  InstanceJavaMode.automatic => '自动选择 Java',
                  InstanceJavaMode.custom => '指定 Java',
                }, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
                SelectableText(
                  instance.javaExecutable(widget.controller.settings),
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 12,
                    color: LauncherColors.of(context).muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppButton(
            '选择 Java',
            secondary: true,
            small: true,
            onPressed: busy
                ? null
                : () => showDialog<bool>(
                    context: context,
                    builder: (_) => InstanceJavaDialog(
                      controller: widget.controller,
                      instance: instance,
                    ),
                  ),
          ),
        ],
      ),
    ]),
    LayoutBuilder(
      builder: (context, constraints) {
        final memory = section('内存', [
          SelectBox<int>(
            key: const ValueKey('instance-memory-mode'),
            compact: true,
            value: ownMemory
                ? automaticMemory
                      ? 0
                      : 1
                : -1,
            items: const {-1: '跟随默认设置', 0: '自动分配', 1: '手动配置'},
            onChanged: busy
                ? null
                : (value) {
                    setOverride(value != -1, ownMemory, const [
                      'minMemory',
                      'maxMemory',
                      'autoMemoryLimit',
                    ]);
                    ownMemory = value != -1;
                    automaticMemory = value == -1
                        ? widget.controller.settings.automaticMemory
                        : value == 0;
                    changed();
                  },
          ),
          const SizedBox(height: 10),
          if (automaticMemory)
            field('autoMemoryLimit', '自动分配上限（MB）', enabled: ownMemory)
          else
            field('maxMemory', '最大内存（MB）', enabled: ownMemory),
          MemoryPreview(
            settings: memoryDraft(),
            platform: widget.controller.platform,
            instance: instance,
          ),
        ]);
        final window = section('游戏窗口', [
          check('单独设置游戏窗口', ownWindow, (v) {
            setOverride(v, ownWindow, const ['width', 'height']);
            ownWindow = v;
          }),
          if (ownWindow) check('全屏启动', fullscreen, (v) => fullscreen = v),
          pair(
            field('width', '宽度（像素）', enabled: ownWindow && !fullscreen),
            field('height', '高度（像素）', enabled: ownWindow && !fullscreen),
          ),
          const Text('启动后最小化 FYL', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          SelectBox<int>(
            compact: true,
            value: minimize,
            items: const {-1: '跟随全局设置', 1: '最小化', 0: '保持窗口'},
            onChanged: busy
                ? null
                : (v) {
                    minimize = v;
                    changed();
                  },
          ),
        ]);
        return constraints.maxWidth >= 720
            ? pair(memory, window)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [memory, window],
              );
      },
    ),
    section('高级启动选项', [
      field('minMemory', '初始内存（MB，留空由 Java 决定）', enabled: ownMemory),
      check('单独设置 JVM 参数', ownJvm, (v) {
        setOverride(v, ownJvm, const ['jvmArguments']);
        ownJvm = v;
      }),
      field(
        'jvmArguments',
        '额外 JVM 参数',
        enabled: ownJvm,
        lines: 2,
        description: '覆盖全局额外 JVM 参数；单个参数包含空格时请加引号。',
      ),
      check('单独设置游戏参数', ownGame, (v) {
        setOverride(v, ownGame, const ['gameArguments']);
        ownGame = v;
      }),
      field('gameArguments', '额外游戏参数', enabled: ownGame),
      check('单独设置启动前命令', ownHook, (v) {
        setOverride(v, ownHook, const ['preLaunchCommand']);
        ownHook = v;
      }),
      field(
        'preLaunchCommand',
        '启动前执行',
        enabled: ownHook,
        description:
            '在游戏目录中执行；Windows 使用 cmd，macOS/Linux 使用 sh。失败时停止启动，最长运行 2 分钟。',
      ),
      check(
        '忽略 Java 版本限制',
        skipJava,
        (v) => skipJava = v,
        subtitle: '仍会检查 Java 是否可运行及架构是否匹配。',
      ),
      const SizedBox(height: 10),
      const Text('下载文件校验', style: TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      SelectBox<int>(
        compact: true,
        value: verify,
        items: const {-1: '跟随全局设置', 1: '开启校验', 0: '关闭校验'},
        onChanged: busy
            ? null
            : (v) {
                verify = v;
                changed();
              },
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: AppButton(
          '恢复启动选项默认值',
          key: const ValueKey('reset-instance-launch-options'),
          secondary: true,
          small: true,
          onPressed: busy ? null : resetLaunchOverrides,
        ),
      ),
    ]),
  ];
  Widget _mods() {
    if (browseMods) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => browseMods = false),
              icon: const Icon(FIcons.arrowLeft, size: 15),
              label: const Text('返回 Mod 管理'),
            ),
          ),
          Expanded(
            child: CommunityPage(
              controller: widget.controller,
              kind: ContentKind.mod,
              onTaskStarted: () => widget.navigate(2),
              onOpenSettings: () => widget.navigate(3),
            ),
          ),
        ],
      );
    }
    return InstanceMods(
      controller: widget.controller,
      instance: instance,
      onDownload: () async {
        await widget.controller.selectInstance(instance);
        if (mounted) setState(() => browseMods = true);
      },
    );
  }

  List<Widget> export() => [
    section('导出整合包', [
      const Text(
        '保存为 .mrpack，按所选内容打包。游戏本体、共享依赖库和账号信息不包含在内。',
        style: TextStyle(fontSize: 12, height: 1.6),
      ),
      const SizedBox(height: 20),
      field('packVersion', '整合包版本号'),
      for (final entry in exportFolders.entries)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(entry.value, style: const TextStyle(fontSize: 12)),
          value: folders.contains(entry.key),
          onChanged: busy
              ? null
              : (v) => setState(() {
                  if (v == true) {
                    folders.add(entry.key);
                  } else {
                    folders.remove(entry.key);
                  }
                }),
        ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text('游戏选项（options.txt）', style: TextStyle(fontSize: 12)),
        value: gameOptions,
        onChanged: busy ? null : (v) => setState(() => gameOptions = v ?? true),
      ),
      const SizedBox(height: 18),
      Align(
        alignment: Alignment.centerLeft,
        child: AppButton(
          '选择位置并导出',
          icon: FIcons.package,
          onPressed: busy || widget.controller.installing ? null : exportPack,
        ),
      ),
    ]),
  ];
}
