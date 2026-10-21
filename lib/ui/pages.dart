import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:window_manager/window_manager.dart';

import '../core/controller.dart';
import '../core/models.dart';
import '../core/pack_import.dart';
import 'theme.dart';
import 'account_widgets.dart';
import 'install_page.dart';
import 'component_icon.dart';
import 'instance_java_dialog.dart';
import '../core/community_models.dart';
import 'community_page.dart';
import 'content_tasks.dart';
import 'instance_details.dart';
import 'instance_icon.dart';
import 'version_log_page.dart';

class PageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;
  const PageHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: c.foreground,
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(subtitle, style: TextStyle(color: c.muted, fontSize: 12)),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 18), trailing!],
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final LauncherController controller;
  final ValueChanged<int> navigate;
  final bool nativeWindow;
  const HomePage({
    required this.controller,
    required this.navigate,
    required this.nativeWindow,
    super.key,
  });
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<void> launch() async {
    final minimize = widget.controller.selectedInstance
        ?.effectiveSettings(widget.controller.settings)
        .minimizeOnLaunch;
    final started = await widget.controller.launch();
    if (widget.nativeWindow && started && minimize == true) {
      await windowManager.minimize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final controller = widget.controller;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(30, 30, 30, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(title: '开始游戏', subtitle: '选择游戏版本和账号。'),
          LayoutBuilder(
            builder: (context, constraints) {
              final children = [_playCard(), _accountCard()];
              return constraints.maxWidth >= 760
                  // Validation text can change card height between frames.
                  // Let each card grow with its content instead of constraining
                  // the account form to an estimated equal height.
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 5, child: children[0]),
                        const SizedBox(width: 18),
                        Expanded(flex: 3, child: children[1]),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        children[0],
                        const SizedBox(height: 18),
                        children[1],
                      ],
                    );
            },
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              const Text(
                '快捷入口',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '${controller.instances.length} 个已安装版本',
                style: TextStyle(color: c.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final cards = [
                _quickCard(
                  FIcons.layers,
                  '版本管理',
                  '管理已安装版本和启动设置',
                  () => widget.navigate(1),
                ),
                _quickCard(
                  FIcons.download,
                  '下载游戏',
                  '从 Minecraft 官方源安装',
                  () => widget.navigate(2),
                ),
                _quickCard(
                  FIcons.settings,
                  '设置',
                  '隔离、Java、内存与更多设置',
                  () => widget.navigate(3),
                ),
              ];
              return constraints.maxWidth >= 650
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < cards.length; i++) ...[
                          if (i > 0) const SizedBox(width: 14),
                          Expanded(child: cards[i]),
                        ],
                      ],
                    )
                  : Column(
                      children: [
                        for (final card in cards) ...[
                          card,
                          const SizedBox(height: 12),
                        ],
                      ],
                    );
            },
          ),
          if (controller.lastExitCode != null) ...[
            const SizedBox(height: 22),
            Surface(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(FIcons.terminal, color: c.muted, size: 18),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '最近一次游戏退出码：${controller.lastExitCode}',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ),
                  AppButton(
                    '查看日志',
                    secondary: true,
                    small: true,
                    onPressed: () => widget.navigate(1),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _playCard() {
    final controller = widget.controller;
    final instance = controller.selectedInstance;
    final c = LauncherColors.of(context);
    final hasAccount = controller.activeAccount != null;
    return Surface(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 156,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [c.accentBackground, c.surface],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Stack(
                children: [
                  Positioned(
                    right: -12,
                    top: -28,
                    child: Transform.rotate(
                      angle: -.22,
                      child: Opacity(
                        opacity: .12,
                        child: ComponentIcon(
                          componentFor(instance?.components ?? ''),
                          size: 170,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (instance != null)
                              InstanceIcon(instance, size: 36)
                            else
                              const ComponentIcon(
                                GameComponent.minecraft,
                                size: 36,
                              ),
                            const SizedBox(width: 9),
                            const Tag('MINECRAFT JAVA EDITION', accent: true),
                          ],
                        ),
                        const Spacer(),
                        Text(
                          instance == null ? '未安装游戏' : instance.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          instance == null
                              ? '在下载管理中选择并安装 Minecraft。'
                              : '${instance.components.isEmpty ? '原版' : instance.components} · ${instance.version} · Java ${instance.javaMajor}+',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (instance != null) ...[
                    SelectBox<String>(
                      value: instance.id,
                      items: {
                        for (final item in controller.instances)
                          item.id: '${item.name} · ${item.version}',
                      },
                      onChanged: controller.preparingLaunch
                          ? null
                          : (id) => controller.selectInstance(
                              controller.instances.firstWhere(
                                (i) => i.id == id,
                              ),
                            ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  FButton(
                    key: const ValueKey('launch-game'),
                    size: FButtonSizeVariant.lg,
                    prefix: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: controller.preparingLaunch
                          ? SizedBox.square(
                              key: const ValueKey('launch-progress'),
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: c.onAccent,
                              ),
                            )
                          : Icon(
                              instance == null ? FIcons.plus : FIcons.play,
                              size: 18,
                            ),
                    ),
                    onPress: instance == null
                        ? () => widget.navigate(2)
                        : controller.preparingLaunch ||
                              controller.installing ||
                              !hasAccount
                        ? null
                        : launch,
                    child: Text(
                      instance == null ? '安装游戏' : '启动游戏',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (instance != null && !hasAccount)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '请先在首页添加或选择账号。',
                        style: TextStyle(color: c.muted, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _accountCard() => HomeAccountCard(
    controller: widget.controller,
    onOpenSettings: () => widget.navigate(3),
  );

  Widget _quickCard(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    final c = LauncherColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Surface(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: c.accent),
                const Spacer(),
                Icon(FIcons.arrowUpRight, size: 14, color: c.muted),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(subtitle, style: TextStyle(color: c.muted, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class InstancesPage extends StatefulWidget {
  final LauncherController controller;
  final ValueChanged<int> navigate;
  final ValueChanged<bool>? onDirty;
  const InstancesPage({
    required this.controller,
    required this.navigate,
    this.onDirty,
    super.key,
  });
  @override
  State<InstancesPage> createState() => InstancesPageState();
}

class InstancesPageState extends State<InstancesPage> {
  String? opened;
  String? openedLog;
  String query = '', category = 'all';
  bool favoritesOnly = false;
  bool importing = false;
  LauncherController get controller => widget.controller;
  void navigate(int index) => widget.navigate(index);
  String categoryOf(GameInstance i) => i.category.isNotEmpty
      ? i.category
      : i.components.isEmpty
      ? '原版'
      : '模组';

  Future<void> importPack() async {
    setState(() => importing = true);
    try {
      if (controller.installing || controller.preparingLaunch) {
        throw StateError('请等待当前任务或游戏结束。');
      }
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Minecraft 整合包', extensions: ['mrpack', 'zip']),
        ],
      );
      if (file == null) return;
      final plan = await inspectModpack(file.path);
      final hash = (await sha256.bind(File(file.path).openRead()).first)
          .toString();
      if (!mounted) return;
      final release = ContentVersion(
        source: plan.source,
        id: hash,
        projectId: 'local-$hash',
        name: plan.version,
        number: plan.version,
        published: DateTime.now(),
        gameVersions: [plan.minecraft],
      );
      final choices = await showDialog<PackChoices>(
        context: context,
        builder: (_) => PackInstallDialog(
          plan: plan,
          release: release,
          isolated: controller.settings.isolateVersions,
        ),
      );
      if (choices == null || !mounted) return;
      final project = ContentProject(
        source: plan.source,
        kind: ContentKind.modpack,
        id: 'local-$hash',
        slug: '',
        name: plan.name,
        summary: '',
        author: '',
        website: '',
      );
      final operation = controller.content.installPack(
        project,
        release,
        plan,
        choices.name,
        isolated: choices.isolated,
        optional: choices.optional,
        onStarted: (_) {
          if (mounted) navigate(2);
        },
      );
      await operation;
    } catch (e) {
      controller.errorMessage = '整合包导入失败：$e';
      controller.notifyListeners();
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (openedLog != null &&
        controller.instances.any((i) => i.id == openedLog)) {
      return VersionLogPage(
        key: ValueKey('version-log-$openedLog'),
        controller: controller,
        instanceId: openedLog!,
        onBack: () => setState(() => openedLog = null),
      );
    }
    if (opened != null && controller.instances.any((i) => i.id == opened)) {
      return InstanceDetailsPage(
        key: ValueKey(opened),
        controller: controller,
        instanceId: opened!,
        onBack: () => setState(() => opened = null),
        onDirty: widget.onDirty ?? (_) {},
        navigate: navigate,
      );
    }
    final c = LauncherColors.of(context);
    final all = controller.instances.toList()
      ..sort((a, b) => (b.favorite ? 1 : 0).compareTo(a.favorite ? 1 : 0));
    final categories = all.map(categoryOf).toSet();
    if (category != 'all' && !categories.contains(category)) category = 'all';
    final visible = all
        .where(
          (i) =>
              (!favoritesOnly || i.favorite) &&
              (category == 'all' || categoryOf(i) == category) &&
              '${i.name} ${i.description} ${i.version}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.all(30),
      children: [
        PageHeader(
          title: '版本管理',
          subtitle: '管理已安装版本、启动设置和 Mod。',
          trailing: AppButton(
            '安装游戏',
            icon: FIcons.plus,
            onPressed: () => navigate(2),
          ),
        ),
        if (controller.instances.isEmpty)
          Surface(
            child: EmptyState(
              icon: FIcons.layers,
              title: '尚未安装游戏',
              description: '在下载管理中安装 Minecraft。',
              action: AppButton(
                '去下载游戏',
                icon: FIcons.download,
                onPressed: () => navigate(2),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              importing ? '正在读取整合包…' : '导入整合包',
              icon: FIcons.folderOpen,
              secondary: true,
              small: true,
              onPressed:
                  importing ||
                      controller.installing ||
                      controller.preparingLaunch
                  ? null
                  : importPack,
            ),
          ),
        ),
        if (all.isNotEmpty) ...[
          AppInput(
            hint: '搜索版本名称、描述或版本',
            onChanged: (v) => setState(() => query = v),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SelectBox<String>(
                  value: category,
                  compact: true,
                  items: {
                    'all': '全部分类',
                    for (final value in categories) value: value,
                  },
                  onChanged: (v) => setState(() => category = v),
                ),
              ),
              const SizedBox(width: 12),
              AppButton(
                favoritesOnly ? '仅看收藏' : '全部版本',
                secondary: !favoritesOnly,
                small: true,
                icon: FIcons.star,
                onPressed: () => setState(() => favoritesOnly = !favoritesOnly),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('没有匹配的游戏版本'),
            ),
        ],
        for (final instance in visible) ...[
          Surface(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: c.accentBackground,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: InstanceIcon(instance, size: 48),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            instance.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${instance.components.isEmpty ? '原版' : instance.components} · ${instance.version} · Java ${instance.javaMajor}+',
                            style: TextStyle(color: c.muted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    if (instance.id == controller.selectedInstance?.id)
                      const Tag('当前选择', accent: true),
                    if (instance.favorite)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(FIcons.star, size: 16),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Tag(instance.isolated ? '版本隔离' : '未隔离'),
                    Tag(categoryOf(instance)),
                    Tag(switch (instance.javaMode) {
                      InstanceJavaMode.inherit => '默认 Java',
                      InstanceJavaMode.automatic => '自动 Java',
                      InstanceJavaMode.custom => '独立 Java',
                    }),
                    if (controller.isInstanceRunning(instance.id))
                      const Tag('正在运行', accent: true),
                  ],
                ),
                const SizedBox(height: 12),
                if (instance.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      instance.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.secondaryText,
                        fontSize: 14,
                        height: 1.6,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                SelectableText(
                  instance.gameDirectory,
                  style: TextStyle(color: c.muted, fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    AppButton(
                      '版本设置',
                      key: ValueKey('instance-settings-${instance.id}'),
                      icon: FIcons.settings2,
                      small: true,
                      onPressed: () => setState(() => opened = instance.id),
                    ),
                    AppButton(
                      '选择并前往启动',
                      icon: FIcons.play,
                      small: true,
                      onPressed: controller.preparingLaunch
                          ? null
                          : () {
                              controller.selectInstance(instance);
                              navigate(0);
                            },
                    ),
                    AppButton(
                      '打开游戏目录',
                      icon: FIcons.folderOpen,
                      secondary: true,
                      small: true,
                      onPressed: () =>
                          controller.openDirectory(instance.gameDirectory),
                    ),
                    AppButton(
                      'Java 设置',
                      key: ValueKey('instance-java-${instance.id}'),
                      icon: FIcons.settings2,
                      secondary: true,
                      small: true,
                      onPressed: () => showDialog<bool>(
                        context: context,
                        builder: (_) => InstanceJavaDialog(
                          controller: controller,
                          instance: instance,
                        ),
                      ),
                    ),
                    AppButton(
                      '运行日志',
                      key: ValueKey('instance-log-${instance.id}'),
                      icon: FIcons.terminal,
                      secondary: true,
                      small: true,
                      onPressed: () => setState(() => openedLog = instance.id),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}

class DownloadsPage extends StatefulWidget {
  final LauncherController controller;
  final ValueChanged<int> navigate;
  const DownloadsPage({
    required this.controller,
    required this.navigate,
    super.key,
  });
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  MinecraftVersion? preparingVersion;
  int tab = 0;
  String query = '';
  @override
  void initState() {
    super.initState();
    if (widget.controller.installing) {
      tab = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (preparingVersion != null) {
      final version = preparingVersion!;
      return InstallPage(
        controller: widget.controller,
        version: version,
        onBack: () => setState(() => preparingVersion = null),
        onInstall: (name, options) {
          setState(() {
            preparingVersion = null;
            tab = 1;
          });
          unawaited(
            widget.controller.install(version, name: name, options: options),
          );
        },
      );
    }
    final c = LauncherColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 30, 30, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const PageHeader(title: '下载管理', subtitle: '安装游戏、Mod 和整合包，查看下载进度。'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (i, title, icon) in [
                (0, '版本列表', FIcons.box),
                (3, 'Mod', FIcons.puzzle),
                (4, '整合包', FIcons.package),
                (
                  1,
                  '下载任务 (${widget.controller.tasks.length + widget.controller.content.tasks.length})',
                  FIcons.download,
                ),
              ])
                AppButton(
                  title,
                  icon: icon,
                  secondary: tab != i,
                  small: true,
                  onPressed: () => setState(() => tab = i),
                ),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: tab == 3 || tab == 4
                ? CommunityPage(
                    key: ValueKey('community-$tab'),
                    controller: widget.controller,
                    kind: tab == 3 ? ContentKind.mod : ContentKind.modpack,
                    onTaskStarted: () => setState(() => tab = 1),
                    onOpenSettings: () => widget.navigate(3),
                  )
                : tab == 0
                ? _versions()
                : _tasks(),
          ),
          if (tab == 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Icon(FIcons.globe, size: 12, color: c.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Minecraft 官方源${widget.controller.manifestFromCache ? ' · 当前显示本地缓存' : ''}',
                      style: TextStyle(color: c.muted, fontSize: 10),
                    ),
                  ),
                  TextButton(
                    onPressed: () => widget.navigate(3),
                    child: Text(
                      '下载与版本设置',
                      style: TextStyle(color: c.accent, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _versions() {
    final controller = widget.controller;
    final c = LauncherColors.of(context);
    final versions = controller.versions
        .where(
          (v) =>
              (v.type == 'release' ||
                  v.type == 'snapshot' && controller.settings.showSnapshots ||
                  (v.type == 'old_beta' || v.type == 'old_alpha') &&
                      controller.settings.showHistorical) &&
              v.id.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    MinecraftVersion? latest;
    for (final version in versions) {
      if (version.id == controller.latestRelease) {
        latest = version;
        break;
      }
    }
    final others = versions
        .where((version) => version.id != latest?.id)
        .toList();
    final leading = latest == null ? 0 : 2;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: AppInput(
                hint: '搜索版本，例如 1.21.1',
                onChanged: (v) => setState(() => query = v),
              ),
            ),
            const SizedBox(width: 12),
            AppButton(
              '刷新',
              icon: FIcons.refreshCw,
              secondary: true,
              onPressed: controller.loadingVersions
                  ? null
                  : controller.refreshVersions,
            ),
          ],
        ),
        const SizedBox(height: 15),
        Expanded(
          child: controller.loadingVersions && controller.versions.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: c.accent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text('正在获取官方版本列表…', style: TextStyle(color: c.muted)),
                    ],
                  ),
                )
              : versions.isEmpty
              ? SingleChildScrollView(
                  child: EmptyState(
                    icon: FIcons.search,
                    title: controller.versions.isEmpty
                        ? '暂时没有版本列表'
                        : '没有找到匹配的版本',
                    description: controller.versions.isEmpty
                        ? '点击刷新，连接 Minecraft 官方版本源。'
                        : '试试其他版本号，或在设置中显示快照与历史版本。',
                  ),
                )
              : ListView.separated(
                  itemCount: leading + (others.isEmpty ? 0 : others.length + 1),
                  separatorBuilder: (_, _) => const SizedBox(height: 9),
                  itemBuilder: (context, index) {
                    if (latest != null && index == 0) {
                      return _versionHeading('最新正式版');
                    }
                    if (latest != null && index == 1) {
                      return _versionCard(latest);
                    }
                    if (index == leading) {
                      return _versionHeading(
                        '${latest == null ? '全部版本' : '其他版本'} (${others.length})',
                      );
                    }
                    return _versionCard(others[index - leading - 1]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _versionHeading(String title) => Padding(
    padding: const EdgeInsets.only(top: 5, bottom: 3),
    child: Text(
      title,
      style: TextStyle(
        color: LauncherColors.of(context).muted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _versionCard(MinecraftVersion version) {
    final controller = widget.controller;
    final c = LauncherColors.of(context);
    final installed = controller.instances.any((i) => i.version == version.id);
    return Surface(
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 15),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: c.raised,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const ComponentIcon(GameComponent.minecraft, size: 40),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        version.id,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (version.id == controller.latestRelease) ...[
                      const SizedBox(width: 9),
                      const Tag('最新正式版', accent: true),
                    ],
                    if (installed) ...[
                      const SizedBox(width: 9),
                      const Tag('已安装'),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '${version.type == 'release'
                      ? '正式版'
                      : version.type == 'snapshot'
                      ? '快照版'
                      : '历史版本'}  ·  ${version.released.toLocal().toIso8601String().substring(0, 10)}',
                  style: TextStyle(color: c.muted, fontSize: 10),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppButton(
            installed ? '再次安装' : '安装',
            key: ValueKey('install-version-${version.id}'),
            icon: FIcons.download,
            secondary: true,
            small: true,
            onPressed: controller.installing
                ? null
                : () => _installDialog(version),
          ),
        ],
      ),
    );
  }

  void _installDialog(MinecraftVersion version) =>
      setState(() => preparingVersion = version);

  Widget _tasks() {
    final controller = widget.controller;
    final c = LauncherColors.of(context);
    if (controller.tasks.isEmpty && controller.content.tasks.isEmpty) {
      return SingleChildScrollView(
        child: EmptyState(
          icon: FIcons.download,
          title: '下载队列很安静',
          description: '选择一个版本开始安装。',
          action: AppButton('浏览版本', onPressed: () => setState(() => tab = 0)),
        ),
      );
    }
    return ListView(
      children: [
        for (final task in controller.content.tasks) ...[
          ContentTaskCard(
            key: ValueKey('content-task-${task.id}'),
            controller: controller,
            task: task,
          ),
          const SizedBox(height: 14),
        ],
        for (final task in controller.tasks) ...[
          Surface(
            padding: const EdgeInsets.all(21),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ComponentIcon(componentFor(task.options.summary), size: 40),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Text(
                        task.instanceName,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Tag(
                      task.stage,
                      accent: task.status == TaskStatus.completed,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (task.status == TaskStatus.running) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: task.progress,
                      minHeight: 5,
                      backgroundColor: c.raised,
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${task.completedFiles} / ${task.totalFiles} 个文件  ·  已传输 ${(task.downloadedBytes / 1048576).toStringAsFixed(1)} MB',
                    style: TextStyle(color: c.muted, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    task.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 10),
                  ),
                  const SizedBox(height: 16),
                  AppButton(
                    '取消下载',
                    icon: FIcons.x,
                    secondary: true,
                    small: true,
                    onPressed: controller.cancelInstall,
                  ),
                ] else if (task.status == TaskStatus.completed) ...[
                  Text(
                    '${task.version.id} 安装完成。',
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  AppButton(
                    '前往启动',
                    icon: FIcons.play,
                    small: true,
                    onPressed: () => widget.navigate(0),
                  ),
                ] else ...[
                  if (task.error != null)
                    SelectableText(
                      task.error!,
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  const SizedBox(height: 14),
                  AppButton(
                    '重新安装',
                    icon: FIcons.refreshCw,
                    small: true,
                    secondary: true,
                    onPressed: controller.installing
                        ? null
                        : () => controller.install(
                            task.version,
                            name: task.instanceName,
                            options: task.options,
                          ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}
