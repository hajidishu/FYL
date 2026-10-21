import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;

import '../core/controller.dart';
import '../core/java_discovery.dart';
import '../core/models.dart';
import 'pages.dart';
import 'java_installation_tile.dart';
import 'theme.dart';

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
  String? error;
  late final JavaDiscovery javaDiscovery;
  List<JavaInstallation> installations = [];
  bool scanningJava = false;
  bool javaScanned = false;
  bool scanCancelled = false;
  String? javaScanError;
  JavaScanProgress javaScanProgress = const JavaScanProgress(0, 0);
  static const groups = ['通用', '游戏与隔离', '默认 Java 与内存', '游戏窗口', '下载与版本', '社区资源'];

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
      'width',
      'height',
      'jvmArguments',
      'gameArguments',
      'preLaunchCommand',
      'parallelDownloads',
      'downloadRetries',
      'timeoutSeconds',
    ]) {
      fields[name] = TextEditingController(text: '${json[name]}');
    }
    fields['curseforgeApiKey'] = TextEditingController(
      text: draft.curseforgeApiKey,
    );
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
          Text(
            '正在搜索常见位置，已检查 ${javaScanProgress.checked} 个候选，发现 ${javaScanProgress.found} 个 Java…',
            style: TextStyle(color: c.muted, fontSize: 11),
          ),
        if (javaScanError != null)
          Text(
            javaScanError!,
            style: TextStyle(
              color: c.dark ? const Color(0xFFEF9990) : Colors.red.shade800,
              fontSize: 11,
            ),
          ),
        if (javaScanned && !scanningJava) ...[
          Text(
            '${scanCancelled ? '查找已停止，' : ''}找到 ${installations.length} 个可运行的 Java',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Text(
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
    next.minMemory = number('minMemory');
    next.maxMemory = number('maxMemory');
    next.width = number('width');
    next.height = number('height');
    next.parallelDownloads = number('parallelDownloads');
    next.downloadRetries = number('downloadRetries');
    next.timeoutSeconds = number('timeoutSeconds');
    final validation = next.validate();
    if (validation != null) {
      setState(() => error = validation);
      return;
    }
    setState(() => saving = true);
    try {
      await widget.controller.saveSettings(next);
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
      padding: const EdgeInsets.fromLTRB(30, 30, 30, 0),
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
          const SizedBox(height: 20),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
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
                    1 => _storage(),
                    2 => _java(),
                    3 => _window(),
                    4 => _downloads(),
                    _ => _community(),
                  },
                  const SizedBox(height: 18),
                  const SizedBox(height: 30),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            style: TextStyle(color: c.muted, fontSize: 11, height: 1.7),
          ),
          const SizedBox(height: 24),
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
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: TextStyle(fontSize: 11, color: c.muted, height: 1.7),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          FSwitch(
            value: value,
            semanticsLabel: title,
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
    padding: const EdgeInsets.only(bottom: 20),
    child: AppInput(
      controller: fields[key],
      label: label,
      description: description,
      hint: hint,
      enabled: enabled,
      maxLines: lines,
      onChanged: (_) => changed(),
    ),
  );

  Widget _general() => _section('外观与行为', '设置界面主题和启动行为。', [
    const Text(
      '界面主题',
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    ),
    const SizedBox(height: 9),
    SelectBox<String>(
      value: draft.theme,
      items: const {'dark': '深色', 'light': '浅色', 'system': '跟随系统'},
      onChanged: (value) {
        draft.theme = value;
        changed();
      },
    ),
    const SizedBox(height: 25),
    _switch(
      '启动游戏后最小化',
      '游戏进程成功启动后，将启动器最小化到任务栏。',
      draft.minimizeOnLaunch,
      (value) => draft.minimizeOnLaunch = value,
    ),
    const Divider(),
    ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('高级登录设置', style: TextStyle(fontSize: 12)),
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
      'free_your_launcher',
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 6),
    const Text(
      '0.1.0 · Minecraft Java Edition 启动器',
      style: TextStyle(fontSize: 11, height: 1.8),
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
          final path = await getDirectoryPath(confirmButtonText: '选择游戏根目录');
          if (path != null && mounted) {
            fields['gameRoot']!.text = path;
            changed();
          }
        },
      ),
    ),
    const SizedBox(height: 25),
    _switch(
      '新版本默认启用版本隔离',
      '开启时，游戏数据保存在 versions/<版本名称>；关闭时保存在游戏根目录。',
      draft.isolateVersions,
      (value) => draft.isolateVersions = value,
    ),
    const Text(
      '此选项不会改变已有版本的存档位置。',
      style: TextStyle(fontSize: 11, height: 1.8),
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
    const SizedBox(height: 24),
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
                final file = await openFile(confirmButtonText: '选择 Java');
                if (file != null && mounted) {
                  fields['javaPath']!.text = file.path;
                  changed();
                }
              },
      ),
    ),
    const SizedBox(height: 26),
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _field('minMemory', '初始内存（MB）')),
        const SizedBox(width: 18),
        Expanded(child: _field('maxMemory', '最大内存（MB）')),
      ],
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
    const Text(
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
        const SizedBox(width: 18),
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
      hint: '填写访问密钥',
      obscureText: true,
      description: '用于 CurseForge 搜索与下载。',
      onChanged: (_) => changed(),
    ),
  ]);

  Widget _downloads() => _section('下载与版本列表', '管理版本筛选与下载。', [
    const Row(
      children: [
        Icon(FIcons.globe, size: 16),
        SizedBox(width: 9),
        Text('Minecraft 官方源', style: TextStyle(fontSize: 13)),
        SizedBox(width: 10),
        Tag('已启用', accent: true),
      ],
    ),
    const SizedBox(height: 25),
    _switch(
      '显示快照版本',
      '在下载列表中显示开发快照和预发布版本。',
      draft.showSnapshots,
      (value) => draft.showSnapshots = value,
    ),
    _switch(
      '显示远古版本',
      '显示官方清单中的 Alpha / Beta 历史版本；部分版本对现代系统的支持有限。',
      draft.showHistorical,
      (value) => draft.showHistorical = value,
    ),
    const Divider(),
    const SizedBox(height: 24),
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _field('parallelDownloads', '并行下载数', description: '1–16'),
        ),
        const SizedBox(width: 18),
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
