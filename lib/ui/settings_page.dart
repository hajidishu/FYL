import '../l10n/app_localizations.dart';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;

import '../core/controller.dart';
import '../core/java_discovery.dart';
import '../core/models.dart';
import '../core/game_process_priority.dart';
import '../core/download_source.dart';
import '../core/build_info.dart';
import 'pages.dart';
import 'java_installation_tile.dart';
import 'theme.dart';
import 'accent_picker.dart';
import 'launcher_background.dart';
import 'memory_preview.dart';
import 'launcher_update_panel.dart';
import 'game_process_priority_setting.dart';

class SettingsPage extends StatefulWidget {
  final LauncherController controller;
  final ValueChanged<bool> onDirty;
  final JavaDiscovery? javaDiscovery;
  const SettingsPage({
    required this.controller,
    required this.onDirty,
    this.javaDiscovery,
    super.key,
  });
  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  late LauncherSettings draft;
  final fields = <String, TextEditingController>{};
  int group = 0;
  bool dirty = false;
  bool saving = false;
  bool migrateData = false;
  String? error;
  late final JavaDiscovery javaDiscovery;
  List<JavaInstallation> installations = [];
  bool scanningJava = false;
  bool javaScanned = false;
  bool scanCancelled = false;
  String? javaScanError;
  JavaScanProgress javaScanProgress = const JavaScanProgress(0, 0);
  static const groups = [
    '通用',
    '外观',
    '游戏与隔离',
    '默认 Java 与内存',
    '游戏窗口',
    '下载与版本',
    '社区资源',
    '日志',
    '数据存储',
  ];

  @override
  void initState() {
    super.initState();
    draft = widget.controller.settings.copy();
    javaDiscovery =
        widget.javaDiscovery ?? JavaDiscovery(widget.controller.platform);
    final json = draft.toJson();
    for (final name in [
      'gameRoot',
      'microsoftClientId',
      'javaPath',
      'minMemory',
      'maxMemory',
      'autoMemoryLimit',
      'width',
      'height',
      'jvmArguments',
      'gameArguments',
      'preLaunchCommand',
      'parallelDownloads',
      'downloadRetries',
      'timeoutSeconds',
      'retainedGameLogs',
    ]) {
      fields[name] = TextEditingController(text: '${json[name]}');
    }
    fields['curseforgeApiKey'] = TextEditingController(
      text: draft.curseforgeApiKey,
    );
    fields['dataDirectory'] = TextEditingController(
      text: widget.controller.supportDirectory,
    );
    if (draft.minMemory == 0) fields['minMemory']!.clear();
  }

  @override
  void dispose() {
    javaDiscovery.cancel();
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

  Future<void> findJava() async {
    if (scanningJava) return;
    setState(() {
      scanningJava = true;
      scanCancelled = false;
      javaScanError = null;
      javaScanProgress = const JavaScanProgress(0, 0);
    });
    try {
      final result = await javaDiscovery.discover(
        runtimeRoots: [
          fields['gameRoot']!.text.trim(),
          ...widget.controller.instances.map((instance) => instance.root),
        ],
        selectedJava: fields['javaPath']!.text.trim(),
        onProgress: (progress) {
          if (mounted) setState(() => javaScanProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        installations = result;
        javaScanned = true;
      });
    } catch (e) {
      if (mounted) setState(() => javaScanError = '查找失败，请重试或手动选择 Java。\n$e');
    } finally {
      if (mounted) setState(() => scanningJava = false);
    }
  }

  void useJava(JavaInstallation installation) {
    fields['javaPath']!.text = installation.executable;
    draft.automaticJava = false;
    changed();
  }

  bool selectedJava(JavaInstallation installation) {
    String key(String path) => widget.controller.platform.os == 'windows'
        ? p.normalize(path).toLowerCase()
        : p.normalize(path);
    return !draft.automaticJava &&
        key(fields['javaPath']!.text.trim()) == key(installation.executable);
  }

  Widget _javaResults() {
    final c = LauncherColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            AppButton(
              scanningJava
                  ? '正在查找…'
                  : javaScanned
                  ? '重新查找可用 Java'
                  : '自动查找可用 Java',
              key: const ValueKey('discover-java'),
              icon: FIcons.search,
              secondary: true,
              small: true,
              onPressed: scanningJava ? null : findJava,
            ),
            if (scanningJava)
              AppButton(
                scanCancelled ? '正在停止…' : '取消查找',
                secondary: true,
                small: true,
                onPressed: scanCancelled
                    ? null
                    : () {
                        setState(() => scanCancelled = true);
                        javaDiscovery.cancel();
                      },
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (scanningJava)
          LText(
            '正在搜索常见位置，已检查 ${javaScanProgress.checked} 个候选，发现 ${javaScanProgress.found} 个 Java…',
            style: TextStyle(color: c.muted, fontSize: 11),
          ),
        if (javaScanError != null)
          LText(
            javaScanError!,
            style: TextStyle(
              color: c.dark ? const Color(0xFFEF9990) : Colors.red.shade800,
              fontSize: 11,
            ),
          ),
        if (javaScanned && !scanningJava) ...[
          LText(
            '${scanCancelled ? '查找已停止，' : ''}找到 ${installations.length} 个可运行的 Java',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          LText(
            installations.isEmpty
                ? '未找到 Java。可以手动选择 java / java.exe，或使用自动准备官方 Java。'
                : '选择默认使用的 Java。',
            style: TextStyle(color: c.muted, fontSize: 11),
          ),
          if (installations.isNotEmpty) ...[
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.separated(
                primary: false,
                shrinkWrap: true,
                itemCount: installations.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (context, index) {
                  final java = installations[index];
                  final selected = selectedJava(java);
                  return JavaInstallationTile(
                    installation: java,
                    platform: widget.controller.platform,
                    selected: selected,
                    enabled: !scanningJava,
                    onSelected: () => useJava(java),
                  );
                },
              ),
            ),
          ],
        ],
      ],
    );
  }

  Future<void> save() async {
    final directory = fields['dataDirectory']!.text.trim();
    final changingDirectory = !p.equals(
      directory,
      widget.controller.supportDirectory,
    );
    if (changingDirectory) {
      if (widget.controller.installing || widget.controller.running) {
        setState(() => error = '请先结束下载任务并关闭正在运行的游戏，再切换数据目录。');
        return;
      }
      try {
        await widget.controller.dataDirectories!.validateDestination(
          directory,
          source: widget.controller.supportDirectory,
          migrate: migrateData,
        );
      } catch (e) {
        if (mounted) setState(() => error = '数据目录无效：$e');
        return;
      }
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const LText('切换数据目录'),
          content: LText(
            migrateData
                ? '将数据迁移到：\n$directory\n\n完成后重新加载启动器并清理旧目录。外部游戏目录保持原位。'
                : '将使用以下目录中的数据：\n$directory\n\n当前数据不会迁移，原目录保留。',
          ),
          actions: [
            AppButton(
              '取消',
              secondary: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            AppButton('应用并重新加载', onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    final next = draft.copy();
    next.gameRoot = fields['gameRoot']!.text.trim();
    next.microsoftClientId = LauncherSettings.resolveMicrosoftClientId(
      fields['microsoftClientId']!.text,
    );
    next.javaPath = fields['javaPath']!.text.trim();
    next.curseforgeApiKey = fields['curseforgeApiKey']!.text.trim();
    next.jvmArguments = fields['jvmArguments']!.text.trim();
    next.gameArguments = fields['gameArguments']!.text.trim();
    next.preLaunchCommand = fields['preLaunchCommand']!.text.trim();
    int number(String key) => int.tryParse(fields[key]!.text.trim()) ?? -1;
    next.minMemory = fields['minMemory']!.text.trim().isEmpty
        ? 0
        : number('minMemory');
    next.maxMemory = number('maxMemory');
    next.autoMemoryLimit = number('autoMemoryLimit');
    next.width = number('width');
    next.height = number('height');
    next.parallelDownloads = number('parallelDownloads');
    next.downloadRetries = number('downloadRetries');
    next.timeoutSeconds = number('timeoutSeconds');
    next.retainedGameLogs = number('retainedGameLogs');
    final validation = next.validate();
    if (validation != null) {
      setState(() => error = validation);
      return;
    }
    setState(() => saving = true);
    try {
      await widget.controller.saveSettings(next);
      if (changingDirectory) {
        await widget.controller.changeDataDirectory(
          directory,
          migrate: migrateData,
        );
      }
      if (!mounted) return;
      draft = next;
      fields['microsoftClientId']!.text = next.microsoftClientId;
      dirty = false;
      widget.onDirty(false);
    } catch (e) {
      if (mounted) error = '设置保存失败：$e';
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PageHeader(
            title: '设置',
            subtitle: '调整启动器和游戏的默认设置。',
            trailing: AppButton(
              saving
                  ? '保存中…'
                  : dirty
                  ? '保存修改'
                  : '已保存',
              icon: FIcons.check,
              onPressed: saving || !dirty ? null : save,
            ),
          ),
          Wrap(
            spacing: 7,
            runSpacing: 9,
            children: [
              for (var index = 0; index < groups.length; index++)
                AppButton(
                  groups[index],
                  small: true,
                  secondary: index != group,
                  onPressed: () => setState(() => group = index),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: LText(
                error!,
                style: TextStyle(
                  color: c.dark ? const Color(0xFFEF9990) : Colors.red.shade800,
                  fontSize: 12,
                ),
              ),
            ),
          Expanded(
            // These few sections have very different heights. Measure them in
            // full so the scrollbar does not change size as more come into view.
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  switch (group) {
                    0 => _general(),
                    1 => _appearance(),
                    2 => _storage(),
                    3 => _java(),
                    4 => _window(),
                    5 => _downloads(),
                    6 => _community(),
                    7 => _logs(),
                    _ => _dataStorage(),
                  },
                  const SizedBox(height: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, String subtitle, List<Widget> children) {
    final c = LauncherColors.of(context);
    return Surface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LText(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          LText(
            subtitle,
            style: TextStyle(color: c.muted, fontSize: 12, height: 1.45),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _switch(
    String title,
    String description,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    final c = LauncherColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LText(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                LText(
                  description,
                  style: TextStyle(fontSize: 12, color: c.muted, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          FSwitch(
            value: value,
            semanticsLabel: AppLocalizations.of(context).text(title),
            onChange: (value) {
              onChanged(value);
              changed();
            },
          ),
        ],
      ),
    );
  }

  Widget _field(
    String key,
    String label, {
    String? description,
    String? hint,
    bool enabled = true,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: AppInput(
      key: ValueKey('settings-field-$key'),
      controller: fields[key],
      label: label,
      inlineLabel: true,
      compact: true,
      description: description,
      hint: hint,
      enabled: enabled,
      maxLines: lines > 1 ? 6 : 1,
      onChanged: (_) => changed(),
    ),
  );

  Widget _logs() => _section('版本日志', '设置每个版本保留的启动日志数量。', [
    _field(
      'retainedGameLogs',
      '每个版本保留的日志份数',
      description: '默认 1 份，可设置为 1–50。运行中或错误报告正在使用的日志暂不清理。',
    ),
  ]);

  Widget _dataStorage() {
    final directories = widget.controller.dataDirectories;
    final enabled =
        directories != null && directories.directoryOverride == null && !saving;
    return _section('启动器数据目录', '保存启动器设置、账号、缓存和默认游戏目录。', [
      const LText('当前目录', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      SelectableText(widget.controller.supportDirectory),
      const SizedBox(height: 18),
      _field(
        'dataDirectory',
        '数据目录',
        enabled: enabled,
        description: directories?.directoryOverride != null
            ? '当前目录由 --data-dir 或 FYL_DATA_DIR 指定。'
            : '修改后保存，将重新加载启动器。',
      ),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          AppButton(
            '选择文件夹',
            icon: FIcons.folderOpen,
            secondary: true,
            small: true,
            key: const ValueKey('choose-data-directory'),
            onPressed: !enabled
                ? null
                : () async {
                    final path = await getDirectoryPath(
                      initialDirectory: widget.controller.supportDirectory,
                      confirmButtonText: tr('选择数据目录'),
                    );
                    if (path != null && mounted) {
                      fields['dataDirectory']!.text = path;
                      changed();
                    }
                  },
          ),
          AppButton(
            '恢复默认目录',
            icon: FIcons.rotateCcw,
            secondary: true,
            small: true,
            key: const ValueKey('reset-data-directory'),
            onPressed: !enabled
                ? null
                : () {
                    fields['dataDirectory']!.text =
                        directories.defaultDirectory;
                    changed();
                  },
          ),
          AppButton(
            '打开当前目录',
            icon: FIcons.folderOpen,
            secondary: true,
            small: true,
            onPressed: () => widget.controller.openDirectory(
              widget.controller.supportDirectory,
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        key: const ValueKey('migrate-launcher-data'),
        title: const LText('自动迁移数据', style: TextStyle(fontSize: 13)),
        subtitle: const LText(
          '包含当前数据目录中的游戏、设置和账号；校验完成后清理旧目录。',
          style: TextStyle(fontSize: 12),
        ),
        value: migrateData,
        onChanged: !enabled
            ? null
            : (value) {
                migrateData = value!;
                changed();
              },
      ),
    ]);
  }

  Widget _appearance() => _section('界面外观', '调整主题和界面色调。', [
    SettingsRow(
      label: '界面主题',
      child: SelectBox<String>(
        compact: true,
        value: draft.theme,
        items: const {'dark': '深色', 'light': '浅色', 'system': '跟随系统'},
        onChanged: (value) {
          draft.theme = value;
          changed();
        },
      ),
    ),
    const SizedBox(height: 14),
    const LText(
      '界面色调',
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    ),
    const SizedBox(height: 9),
    Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Color(0xff000000 | (draft.accentColor ?? 0x237852)),
            shape: BoxShape.circle,
          ),
        ),
        LText(
          draft.accentColor == null
              ? '默认绿色'
              : '#${draft.accentColor!.toRadixString(16).padLeft(6, '0').toUpperCase()}',
        ),
        AppButton(
          '选择色调',
          key: const ValueKey('choose-accent'),
          secondary: true,
          small: true,
          onPressed: saving
              ? null
              : () async {
                  final value = await showDialog<int>(
                    context: context,
                    builder: (_) =>
                        AccentPicker(initial: draft.accentColor ?? 0x237852),
                  );
                  if (!mounted || value == null) return;
                  draft.accentColor = value;
                  changed();
                },
        ),
        AppButton(
          '重置色调',
          key: const ValueKey('reset-accent'),
          secondary: true,
          small: true,
          onPressed: saving || draft.accentColor == null
              ? null
              : () {
                  draft.accentColor = null;
                  changed();
                },
        ),
      ],
    ),
    const SizedBox(height: 14),
    const LText(
      '启动器背景',
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    ),
    const SizedBox(height: 9),
    Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        AppButton(
          '选择背景图片',
          key: const ValueKey('choose-background'),
          icon: FIcons.image,
          secondary: true,
          small: true,
          onPressed: saving
              ? null
              : () async {
                  final image = await openFile(
                    acceptedTypeGroups: [
                      XTypeGroup(
                        label: tr('图片'),
                        extensions: ['png', 'jpg', 'jpeg', 'webp'],
                      ),
                    ],
                  );
                  if (image == null || !mounted) return;
                  try {
                    final path = await importLauncherBackground(
                      image.path,
                      widget.controller.supportDirectory,
                    );
                    if (!mounted) return;
                    draft.backgroundPath = path;
                    changed();
                  } catch (e) {
                    if (mounted) setState(() => error = '背景图片读取失败：$e');
                  }
                },
        ),
        AppButton(
          '移除背景',
          key: const ValueKey('remove-background'),
          secondary: true,
          small: true,
          onPressed: saving || draft.backgroundPath == null
              ? null
              : () {
                  draft.backgroundPath = null;
                  changed();
                },
        ),
      ],
    ),
    if (draft.backgroundPath?.isNotEmpty == true) ...[
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(draft.backgroundPath!),
          height: 130,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const LText('背景图片无法读取，请重新选择。'),
        ),
      ),
      const SizedBox(height: 10),
      LText('背景可见度 ${((draft.backgroundOpacity ?? .35) * 100).round()}%'),
      Slider(
        key: const ValueKey('background-opacity'),
        value: (draft.backgroundOpacity ?? .35).clamp(0, 1),
        onChanged: (value) {
          draft.backgroundOpacity = value;
          changed();
        },
      ),
    ],
  ]);

  Widget _general() => _section('启动行为', '设置启动器行为和登录选项。', [
    SettingsRow(
      label: '语言 / Language',
      child: SelectBox<String>(
        key: const ValueKey('launcher-language'),
        compact: true,
        value: draft.language,
        items: launcherLanguages,
        onChanged: (value) {
          draft.language = value;
          changed();
        },
      ),
    ),
    const SizedBox(height: 14),
    _switch(
      '启动游戏后最小化',
      '游戏进程成功启动后，将启动器最小化到任务栏。',
      draft.minimizeOnLaunch,
      (value) => draft.minimizeOnLaunch = value,
    ),
    const Divider(),
    ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const LText('高级登录设置', style: TextStyle(fontSize: 12)),
      children: [
        _field(
          'microsoftClientId',
          '微软登录应用 Client ID',
          hint: LauncherSettings.defaultMicrosoftClientId,
          description: '自定义登录应用；清空并保存可恢复默认。',
        ),
      ],
    ),
    const SizedBox(height: 18),
    const Text(
      'FYL',
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 6),
    const LText(
      '${launcherVersion == 'development' ? '开发版' : 'v$launcherVersion'} · Minecraft Java Edition 启动器',
      style: TextStyle(fontSize: 11, height: 1.8),
    ),
    const SizedBox(height: 16),
    _switch(
      '启动时检查更新',
      '在后台检查 FYL 新版本。',
      draft.checkLauncherUpdates,
      (value) => draft.checkLauncherUpdates = value,
    ),
    const SizedBox(height: 10),
    SettingsRow(
      label: '更新渠道',
      child: SelectBox<String>(
        compact: true,
        value: draft.launcherUpdateChannel,
        items: const {'stable': '正式版', 'preview': '正式版与测试版'},
        onChanged: (value) {
          draft.launcherUpdateChannel = value;
          changed();
        },
      ),
    ),
    const SizedBox(height: 16),
    LauncherUpdatePanel(
      controller: widget.controller,
      channel: draft.launcherUpdateChannel,
      canRestart: !dirty && !saving,
    ),
  ]);

  Widget _storage() => _section('游戏目录与版本隔离', '以下选项用于新安装的版本；已有版本继续使用创建时记录的目录。', [
    _field(
      'gameRoot',
      '游戏根目录',
      description: '包含 versions、assets、libraries 等文件夹。',
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: AppButton(
        '选择文件夹',
        icon: FIcons.folderOpen,
        secondary: true,
        small: true,
        onPressed: () async {
          final path = await getDirectoryPath(confirmButtonText: tr('选择游戏根目录'));
          if (path != null && mounted) {
            fields['gameRoot']!.text = path;
            changed();
          }
        },
      ),
    ),
    const SizedBox(height: 14),
    _switch(
      '新版本默认启用版本隔离',
      '开启时，游戏数据保存在 versions/<版本名称>；关闭时保存在游戏根目录。',
      draft.isolateVersions,
      (value) => draft.isolateVersions = value,
    ),
    const SizedBox(height: 12),
    _switch(
      '自动将 Minecraft 游戏设为中文',
      '为新安装的游戏设置简体中文。',
      draft.autoChinese,
      (value) => draft.autoChinese = value,
    ),
  ]);

  Widget _java() => _section('默认 Java 与内存', '版本可在各自的 Java 设置中覆盖默认选择。', [
    _switch(
      '自动准备官方 Java',
      '自动下载游戏所需的 Java；关闭后使用下方指定的 Java。',
      draft.automaticJava,
      (value) => draft.automaticJava = value,
    ),
    _javaResults(),
    const SizedBox(height: 14),
    _field(
      'javaPath',
      'Java 可执行文件',
      hint: widget.controller.platform.os == 'windows'
          ? r'C:\Java\bin\java.exe'
          : '/path/to/java/bin/java',
      enabled: !draft.automaticJava,
      description: '请选择 java / java.exe；Java 架构需要与当前系统匹配。',
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: AppButton(
        '选择 Java',
        icon: FIcons.folderOpen,
        secondary: true,
        small: true,
        onPressed: draft.automaticJava
            ? null
            : () async {
                final file = await openFile(confirmButtonText: tr('选择 Java'));
                if (file != null && mounted) {
                  fields['javaPath']!.text = file.path;
                  changed();
                }
              },
      ),
    ),
    const SizedBox(height: 16),
    SelectBox<bool>(
      key: const ValueKey('default-memory-mode'),
      value: draft.automaticMemory,
      items: const {true: '自动分配内存', false: '手动配置内存'},
      onChanged: (value) {
        draft.automaticMemory = value;
        changed();
      },
    ),
    const SizedBox(height: 14),
    if (draft.automaticMemory)
      _field('autoMemoryLimit', '自动分配上限（MB）')
    else
      _field('maxMemory', '最大内存（MB）'),
    MemoryPreview(
      settings: draft.copy()
        ..jvmArguments = fields['jvmArguments']!.text.trim()
        ..minMemory = fields['minMemory']!.text.trim().isEmpty
            ? 0
            : int.tryParse(fields['minMemory']!.text) ?? -1
        ..maxMemory = int.tryParse(fields['maxMemory']!.text) ?? -1
        ..autoMemoryLimit = int.tryParse(fields['autoMemoryLimit']!.text) ?? -1,
      platform: widget.controller.platform,
      probe: widget.controller.memoryProbe,
    ),
    const LText('高级内存设置', style: TextStyle(fontWeight: FontWeight.w600)),
    const SizedBox(height: 12),
    _field(
      'minMemory',
      '初始内存（MB）',
      hint: '由 Java 决定',
      description: '留空时由 Java 决定初始内存。',
    ),
    _field(
      'jvmArguments',
      '额外 JVM 参数',
      hint: '-XX:+UseG1GC',
      lines: 3,
      description: '使用空格分隔，含空格的单个参数使用引号。',
    ),
    _field('gameArguments', '额外游戏参数', lines: 2),
    _field(
      'preLaunchCommand',
      '启动前命令',
      lines: 2,
      description: '在游戏目录执行，最长运行 2 分钟；命令失败时停止启动。',
    ),
    if (widget.controller.platform.os == 'windows') ...[
      GameProcessPrioritySetting(
        scope: 'default',
        value: draft.gameProcessPriority,
        onChanged: saving
            ? null
            : (value) {
                draft.gameProcessPriority = value ?? GameProcessPriority.normal;
                changed();
              },
      ),
      const SizedBox(height: 16),
    ],
    const LText(
      '如果尚未准备 Java，可在版本设置中使用“补全与修复文件”下载运行时。',
      style: TextStyle(fontSize: 11, height: 1.7),
    ),
  ]);

  Widget _window() => _section('游戏窗口', '这些选项会在下一次启动 Minecraft 时应用。', [
    _switch(
      '全屏启动',
      '直接以全屏模式进入游戏；关闭后使用下方窗口尺寸。',
      draft.fullscreen,
      (value) => draft.fullscreen = value,
    ),
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _field('width', '窗口宽度（像素）', enabled: !draft.fullscreen),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _field('height', '窗口高度（像素）', enabled: !draft.fullscreen),
        ),
      ],
    ),
  ]);

  Widget _community() => _section('社区资源', '管理内容来源的访问配置。', [
    AppInput(
      controller: fields['curseforgeApiKey'],
      label: 'CurseForge API Key',
      inlineLabel: true,
      compact: true,
      hint: '填写访问密钥',
      obscureText: true,
      description: '用于 CurseForge 搜索与下载。',
      onChanged: (_) => changed(),
    ),
  ]);

  Widget _downloads() => _section('下载与版本列表', '管理版本筛选与下载。', [
    SettingsRow(
      label: '游戏下载源',
      child: SelectBox<DownloadSource>(
        compact: true,
        value: draft.downloadSource,
        items: {
          for (final source in DownloadSource.values) source: source.label,
        },
        onChanged: (value) {
          draft.downloadSource = value;
          changed();
        },
      ),
    ),
    const SizedBox(height: 8),
    LText(
      draft.downloadSource.attribution,
      style: TextStyle(
        fontSize: 12,
        color: LauncherColors.of(context).secondaryText,
      ),
    ),
    const LText(
      '用于 Minecraft、Java 运行库和游戏组件下载。',
      style: TextStyle(fontSize: 12),
    ),
    const SizedBox(height: 14),
    _switch(
      '默认展开预览版',
      '打开版本列表时展开快照和预发布版本分组。',
      draft.showSnapshots,
      (value) => draft.showSnapshots = value,
    ),
    _switch(
      '默认展开远古版',
      '打开版本列表时展开 Alpha / Beta 等远古版本分组。',
      draft.showHistorical,
      (value) => draft.showHistorical = value,
    ),
    const Divider(),
    const SizedBox(height: 14),
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _field('parallelDownloads', '并行下载数', description: '1–16'),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _field('downloadRetries', '失败重试次数', description: '0–5'),
        ),
      ],
    ),
    _field(
      'timeoutSeconds',
      '连接 / 无数据超时（秒）',
      description: '5–300 秒；用于下一次开始的下载任务。',
    ),
    _switch(
      '校验下载文件 SHA-1',
      '检查文件完整性，自动重新下载损坏的文件。',
      draft.verifyDownloads,
      (value) => draft.verifyDownloads = value,
    ),
  ]);
}
