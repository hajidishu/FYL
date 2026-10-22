import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';
import '../core/community_catalog.dart';
import '../core/community_models.dart';
import '../core/controller.dart';
import '../core/mod_catalog.dart';
import '../core/models.dart';
import '../core/network.dart';
import '../core/pack_import.dart';
import '../core/install_options.dart';
import '../core/resource_packs.dart';
import 'theme.dart';
import 'content_metadata.dart';

typedef ModSavePicker = Future<String?> Function(String directory, String name);
Future<String?> pickModSaveLocation(String directory, String name) async {
  await Directory(directory).create(recursive: true);
  final location = await getSaveLocation(
    initialDirectory: directory,
    suggestedName: name,
    acceptedTypeGroups: [
      XTypeGroup(
        label: name.toLowerCase().endsWith('.jar')
            ? 'Minecraft Mod'
            : 'Minecraft 资源',
        extensions: [p.extension(name).substring(1)],
      ),
    ],
    confirmButtonText: '保存',
  );
  return location?.path;
}

Map<String, String> contentLoaderFilters(ContentKind kind) => switch (kind) {
  ContentKind.shader => const {
    '': '全部光影类型',
    'iris': 'Iris',
    'optifine': 'OptiFine',
  },
  ContentKind.mod || ContentKind.modpack => const {
    '': '全部加载器',
    'forge': 'Forge',
    'neoforge': 'NeoForge',
    'fabric': 'Fabric',
    'quilt': 'Quilt',
  },
  _ => const {},
};

class CommunityPage extends StatefulWidget {
  final LauncherController controller;
  final ContentKind kind;
  final VoidCallback onTaskStarted, onOpenSettings;
  final CommunityCatalog? catalog;
  final ModSavePicker? savePicker;
  const CommunityPage({
    required this.controller,
    required this.kind,
    required this.onTaskStarted,
    required this.onOpenSettings,
    this.catalog,
    this.savePicker,
    super.key,
  });
  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  late final catalog =
      widget.catalog ?? CommunityCatalog(widget.controller.settings.copy());
  final query = TextEditingController();
  late final minecraft = TextEditingController(
    text: widget.kind.hasTarget
        ? widget.controller.selectedInstance?.version ?? ''
        : '',
  );
  String? targetId;
  String source = 'all', loader = '';
  bool newest = false, loading = false, hasMore = false;
  int page = 0;
  String? searchError;
  List<ContentProject> projects = [];
  List<String> notices = [];
  ContentProject? selected;
  CancellationToken token = CancellationToken();
  @override
  void initState() {
    super.initState();
    targetId = widget.controller.selectedInstance?.id;
    if (widget.kind == ContentKind.mod &&
        widget.controller.selectedInstance != null) {
      loader = instanceModLoader(widget.controller.selectedInstance!) ?? '';
    }
    unawaited(search());
  }

  @override
  void dispose() {
    token.cancel();
    catalog.close();
    query.dispose();
    minecraft.dispose();
    super.dispose();
  }

  Future<void> search({bool next = false}) async {
    token.cancel();
    final request = CancellationToken();
    token = request;
    setState(() {
      loading = true;
      if (!next) {
        page = 0;
        projects = [];
        hasMore = false;
      }
      searchError = null;
    });
    ContentSearchResult result;
    try {
      result = await catalog.search(
        kind: widget.kind,
        query: query.text.trim(),
        minecraft: minecraft.text.trim(),
        loader: loader,
        page: next ? page + 1 : 0,
        source: source == 'all' ? null : ContentSource.values.byName(source),
        newest: newest,
        token: request,
      );
    } on Cancelled {
      return;
    } catch (e) {
      if (mounted && !request.cancelled) {
        setState(() {
          loading = false;
          searchError = '$e';
          notices = ['$e'];
        });
      }
      return;
    }
    if (!mounted || request.cancelled) return;
    setState(() {
      if (result.failed) {
        notices = result.notices;
        searchError = '社区来源暂时无法连接';
        loading = false;
        return;
      }
      if (next) page++;
      final ids = projects.map((p) => '${p.source.name}:${p.id}').toSet();
      projects.addAll(
        result.projects.where((p) => ids.add('${p.source.name}:${p.id}')),
      );
      notices = result.notices;
      searchError = result.failed ? '社区来源暂时无法连接' : null;
      hasMore = result.hasMore;
      loading = false;
    });
  }

  GameInstance? get target =>
      widget.controller.instances.where((i) => i.id == targetId).firstOrNull;
  @override
  Widget build(BuildContext context) {
    final releases = widget.controller.versions
        .where((version) => version.type == 'release')
        .map((version) => version.id)
        .toList();
    if (selected != null) {
      return ContentDetails(
        project: selected!,
        controller: widget.controller,
        catalog: catalog,
        target: target,
        initialMinecraft: minecraft.text.trim(),
        initialLoader: loader,
        onBack: () => setState(() => selected = null),
        onTaskStarted: widget.onTaskStarted,
        savePicker: widget.savePicker ?? pickModSaveLocation,
      );
    }
    final c = LauncherColors.of(context);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Surface(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.kind.hasTarget &&
                        widget.controller.instances.isNotEmpty) ...[
                      const Text('目标版本', style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 7),
                      SelectBox<String>(
                        compact: true,
                        value: targetId ?? widget.controller.instances.first.id,
                        items: {
                          for (final instance in widget.controller.instances)
                            instance.id:
                                '${instance.name} · ${instance.version}',
                        },
                        onChanged: (value) {
                          setState(() {
                            targetId = value;
                            minecraft.text = target!.version;
                            loader = widget.kind == ContentKind.mod
                                ? instanceModLoader(target!) ?? ''
                                : '';
                          });
                          unawaited(search());
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: AppInput(
                            controller: query,
                            hint: '搜索${widget.kind.label}',
                          ),
                        ),
                        const SizedBox(width: 10),
                        AppButton(
                          loading ? '正在搜索…' : '搜索',
                          key: const ValueKey('search-community'),
                          icon: FIcons.search,
                          small: true,
                          onPressed: loading ? null : () => search(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth >= 600
                            ? (constraints.maxWidth - 30) / 4
                            : (constraints.maxWidth - 10) / 2;
                        return Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            SizedBox(
                              width: width,
                              child: AppInput(
                                controller: minecraft,
                                hint: 'Minecraft 版本',
                              ),
                            ),
                            if (contentLoaderFilters(widget.kind).isNotEmpty)
                              SizedBox(
                                width: width,
                                child: SelectBox<String>(
                                  compact: true,
                                  value: loader,
                                  items: contentLoaderFilters(widget.kind),
                                  onChanged: (v) => setState(() => loader = v),
                                ),
                              ),
                            SizedBox(
                              width: width,
                              child: SelectBox<String>(
                                compact: true,
                                value: source,
                                items: const {
                                  'all': '全部来源',
                                  'modrinth': 'Modrinth',
                                  'curseforge': 'CurseForge',
                                },
                                onChanged: (v) => setState(() => source = v),
                              ),
                            ),
                            SizedBox(
                              width: width,
                              child: SelectBox<bool>(
                                compact: true,
                                value: newest,
                                items: const {false: '最多下载', true: '最近更新'},
                                onChanged: (v) => setState(() => newest = v),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              if (notices.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          notices.join('\n'),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.muted, fontSize: 11),
                        ),
                      ),
                      if (widget.controller.settings.curseforgeApiKey.isEmpty)
                        TextButton(
                          onPressed: widget.onOpenSettings,
                          child: const Text('配置来源'),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        if (loading && projects.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (projects.isEmpty && searchError != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('社区搜索失败', style: TextStyle(color: c.muted)),
                  const SizedBox(height: 10),
                  AppButton(
                    '重试搜索',
                    key: const ValueKey('retry-community-search'),
                    secondary: true,
                    onPressed: loading ? null : () => search(),
                  ),
                ],
              ),
            ),
          )
        else if (projects.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text('没有找到匹配的项目', style: TextStyle(color: c.muted)),
            ),
          )
        else
          SliverList.separated(
            itemCount: projects.length + (hasMore ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(height: 9),
            itemBuilder: (context, index) {
              if (index == projects.length) {
                return AppButton(
                  loading
                      ? '正在加载…'
                      : searchError == null
                      ? '加载更多'
                      : '重试加载',
                  secondary: true,
                  onPressed: loading ? null : () => search(next: true),
                );
              }
              final project = projects[index];
              return InkWell(
                onTap: () => setState(() => selected = project),
                borderRadius: BorderRadius.circular(14),
                child: Surface(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ProjectIcon(project: project, size: 64),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    project.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SourceBadge(project.source),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              project.summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.secondaryText,
                                fontSize: 14,
                                height: 1.6,
                                letterSpacing: 0,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ProjectMetadata(
                              project: project,
                              releases: releases,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class ProjectIcon extends StatelessWidget {
  final ContentProject project;
  final double size;
  const ProjectIcon({required this.project, this.size = 72, super.key});
  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(project.icon ?? '');
    final fallback = Container(
      color: LauncherColors.of(context).raised,
      child: Icon(
        FIcons.box,
        color: LauncherColors.of(context).accent,
        size: size * .5,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: SizedBox.square(
        dimension: size,
        child: uri?.scheme == 'https'
            ? Image.network(
                uri.toString(),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                errorBuilder: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }
}

class SourceBadge extends StatelessWidget {
  final ContentSource source;
  const SourceBadge(this.source, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color:
          (source == ContentSource.modrinth
                  ? const Color(0xFF27936A)
                  : const Color(0xFFB56B28))
              .withValues(alpha: .13),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      source.label,
      style: TextStyle(
        color: LauncherColors.of(context).foreground,
        fontSize: 12,
      ),
    ),
  );
}

String _date(DateTime value) =>
    value.toLocal().toIso8601String().substring(0, 10);

class ContentDetails extends StatefulWidget {
  final ContentProject project;
  final LauncherController controller;
  final CommunityCatalog catalog;
  final GameInstance? target;
  final String initialMinecraft, initialLoader;
  final VoidCallback onBack, onTaskStarted;
  final ModSavePicker savePicker;
  const ContentDetails({
    required this.project,
    required this.controller,
    required this.catalog,
    required this.target,
    required this.initialMinecraft,
    required this.initialLoader,
    required this.onBack,
    required this.onTaskStarted,
    required this.savePicker,
    super.key,
  });
  @override
  State<ContentDetails> createState() => _ContentDetailsState();
}

class _ContentDetailsState extends State<ContentDetails> {
  late String minecraft = widget.initialMinecraft;
  late String loader = widget.initialLoader;
  List<ContentVersion> versions = [];
  final expanded = <String>{};
  CancellationToken token = CancellationToken();
  bool loading = true,
      hasMore = false,
      working = false,
      dependencies = true,
      showDescription = false;
  int page = 0;
  String? error, description;
  @override
  void initState() {
    super.initState();
    unawaited(load());
    unawaited(loadDescription());
  }

  @override
  void dispose() {
    token.cancel();
    super.dispose();
  }

  Future<void> loadDescription() async {
    try {
      final value = await widget.catalog.description(widget.project, token);
      if (mounted) setState(() => description = value);
    } catch (_) {
      /* The project summary remains available. */
    }
  }

  Future<void> load({bool next = false}) async {
    token.cancel();
    token = CancellationToken();
    final request = token;
    setState(() {
      loading = true;
      error = null;
      if (!next) {
        versions = [];
        page = 0;
      }
    });
    try {
      final result = await widget.catalog.versions(
        widget.project,
        request,
        minecraft: minecraft,
        loader: loader,
        page: next ? page + 1 : 0,
      );
      if (!mounted || request.cancelled) return;
      setState(() {
        if (next) page++;
        versions.addAll(result.versions);
        hasMore = result.hasMore;
        loading = false;
      });
    } catch (e) {
      if (mounted && !request.cancelled) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> install(ContentVersion release) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      if (widget.project.kind == ContentKind.mod) {
        if (!widget.project.clientSupported) {
          throw StateError('该模组仅适用于服务端。');
        }
        final target = widget.target;
        if (target == null) throw StateError('请先创建并选择一个游戏版本。');
        if (instanceModLoader(target) == null) {
          throw StateError('此版本尚未安装模组加载器。');
        }
        if (!release.supports(target.version, instanceModLoader(target))) {
          throw StateError('此版本与目标版本不兼容。');
        }
        if (widget.controller.isGameDirectoryInUse(target.gameDirectory)) {
          throw StateError('请先关闭目标版本的游戏。');
        }
        final file = release.files
            .where((f) => f.name.endsWith('.jar'))
            .firstOrNull;
        if (file == null) throw StateError('此版本没有可用的 JAR 文件。');
        final directory = p.join(target.gameDirectory, 'mods');
        final path = await widget.savePicker(directory, file.name);
        if (path == null) return;
        if (!mounted) return;
        final operation = widget.controller.content.installMod(
          widget.project,
          release,
          target,
          path.toLowerCase().endsWith('.jar') ? path : '$path.jar',
          dependencies: dependencies,
          onStarted: (_) {
            if (mounted) widget.onTaskStarted();
          },
        );
        await operation;
      } else if (widget.project.kind.isResource) {
        final target = widget.target;
        if (target == null) throw StateError('请先创建并选择一个游戏版本。');
        if (widget.controller.isGameDirectoryInUse(target.gameDirectory)) {
          throw StateError('请先关闭目标版本的游戏。');
        }
        final file = resourceFile(widget.project, release, target);
        String? world;
        if (widget.project.kind == ContentKind.datapack) {
          final worlds = await dataPackWorlds(target);
          if (worlds.isEmpty) throw StateError('此版本没有可用存档，请先创建存档。');
          if (!mounted) return;
          setState(() => working = false);
          world = await showDialog<String>(
            context: context,
            builder: (_) => DataPackWorldDialog(worlds: worlds),
          );
          if (world == null || !mounted) return;
          setState(() => working = true);
        }
        final directory = resourceDirectory(
          target,
          widget.project.kind,
          world: world,
        );
        final path = await widget.savePicker(directory, file.name);
        if (path == null || !mounted) return;
        await widget.controller.content.installResource(
          widget.project,
          release,
          target,
          path.toLowerCase().endsWith('.zip') ? path : '$path.zip',
          onStarted: (_) {
            if (mounted) widget.onTaskStarted();
          },
        );
      } else {
        String? local;
        final file = release.files
            .where((f) => f.name.endsWith('.zip') || f.name.endsWith('.mrpack'))
            .firstOrNull;
        if (file?.urls.isEmpty == true) {
          final selected = await openFile(
            acceptedTypeGroups: const [
              XTypeGroup(label: '整合包', extensions: ['zip', 'mrpack']),
            ],
          );
          if (selected == null) return;
          local = selected.path;
        }
        final plan = await widget.controller.content.preparePack(
          widget.project,
          release,
          token,
          localPath: local,
        );
        if (!mounted) return;
        setState(() => working = false);
        final choices = await showDialog<PackChoices>(
          context: context,
          builder: (_) => PackInstallDialog(
            plan: plan,
            release: release,
            isolated: widget.controller.settings.isolateVersions,
          ),
        );
        if (choices == null || !mounted) return;
        setState(() => working = true);
        final operation = widget.controller.content.installPack(
          widget.project,
          release,
          plan,
          choices.name,
          isolated: choices.isolated,
          optional: choices.optional,
          onStarted: (_) {
            if (mounted) widget.onTaskStarted();
          },
        );
        await operation;
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final project = widget.project;
    final releases = widget.controller.versions
        .where((version) => version.type == 'release')
        .map((version) => version.id)
        .toList();
    final games = {
      ...project.gameVersions.where((v) => RegExp(r'^\d+\.\d+').hasMatch(v)),
      ...versions.expand((v) => v.gameVersions),
      if (minecraft.isNotEmpty) minecraft,
    }.toList()..sort((a, b) => compareComponentVersions(b, a));
    final groups = <String, List<ContentVersion>>{};
    for (final release in versions) {
      final key = minecraft.isNotEmpty
          ? minecraft
          : release.gameVersions.isEmpty
          ? '其他版本'
          : (release.gameVersions.toList()
                  ..sort((a, b) => compareComponentVersions(b, a)))
                .first;
      (groups[key] ??= []).add(release);
    }
    final groupNames = groups.keys.toList()
      ..sort((a, b) => compareComponentVersions(b, a));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: widget.onBack,
              tooltip: '返回搜索',
              icon: const Icon(FIcons.arrowLeft, size: 18),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SourceBadge(project.source),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Surface(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ProjectIcon(project: project),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  project.summary,
                                  style: TextStyle(
                                    color: c.secondaryText,
                                    fontSize: 14,
                                    height: 1.6,
                                    letterSpacing: 0,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                ProjectMetadata(
                                  project: project,
                                  releases: releases,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (project.categories.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: project.categories
                              .take(8)
                              .map((v) => Tag(v))
                              .toList(),
                        ),
                      ],
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          AppButton(
                            '项目页面',
                            icon: FIcons.externalLink,
                            secondary: true,
                            small: true,
                            onPressed: () => launchUrl(
                              Uri.parse(project.website),
                              mode: LaunchMode.externalApplication,
                            ),
                          ),
                          AppButton(
                            '复制名称',
                            secondary: true,
                            small: true,
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: project.name),
                            ),
                          ),
                          AppButton(
                            showDescription ? '收起介绍' : '项目介绍',
                            secondary: true,
                            small: true,
                            onPressed: () => setState(
                              () => showDescription = !showDescription,
                            ),
                          ),
                        ],
                      ),
                      if (showDescription) ...[
                        const SizedBox(height: 14),
                        SelectableText(
                          description ?? project.summary,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.65,
                            letterSpacing: 0,
                            color: c.secondaryText,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: SelectBox<String>(
                        compact: true,
                        value: minecraft,
                        items: {
                          '': '全部游戏版本',
                          for (final game in games) game: game,
                        },
                        onChanged: working
                            ? null
                            : (value) {
                                setState(() => minecraft = value);
                                unawaited(load());
                              },
                      ),
                    ),
                    if (contentLoaderFilters(project.kind).isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: SelectBox<String>(
                          compact: true,
                          value: loader,
                          items: contentLoaderFilters(project.kind),
                          onChanged: working
                              ? null
                              : (value) {
                                  setState(() => loader = value);
                                  unawaited(load());
                                },
                        ),
                      ),
                    ],
                  ],
                ),
                if (project.kind.hasTarget) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.target == null
                        ? '请先创建并选择一个游戏版本。'
                        : '安装到 ${widget.target!.name}',
                    style: TextStyle(color: c.muted, fontSize: 11),
                  ),
                  if (project.kind == ContentKind.mod)
                    Row(
                      children: [
                        Checkbox(
                          value: dependencies,
                          onChanged: working
                              ? null
                              : (v) => setState(() => dependencies = v ?? true),
                        ),
                        const Expanded(
                          child: Text('下载必需依赖', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                ],
                if (working)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(minHeight: 3),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SelectableText(
                      error!,
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (versions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('没有匹配的发布版本', style: TextStyle(color: c.muted)),
                  ),
                for (var i = 0; i < groupNames.length; i++) ...[
                  const SizedBox(height: 10),
                  Surface(
                    padding: EdgeInsets.zero,
                    child: ExpansionTile(
                      key: ValueKey(
                        '${project.id}:${groupNames[i]}:$minecraft:$loader',
                      ),
                      initiallyExpanded: i == 0,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                      title: Text(
                        groupNames[i],
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '${groups[groupNames[i]]!.length} 个版本',
                        style: TextStyle(color: c.muted, fontSize: 10),
                      ),
                      children: [
                        for (final release in groups[groupNames[i]]!)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                            child: Row(
                              children: [
                                ProjectIcon(project: project, size: 40),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        release.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      SupportedContentVersions(
                                        gameVersions: release.gameVersions,
                                        loaders: release.loaders,
                                        releases: releases,
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${_date(release.published)} · ${switch (release.releaseType) {
                                          'beta' => '测试版',
                                          'alpha' => '预览版',
                                          _ => '正式版',
                                        }}',
                                        style: TextStyle(
                                          color: c.muted,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                AppButton(
                                  project.kind.hasTarget ? '下载' : '安装',
                                  key: ValueKey(
                                    'install-content-${release.id}',
                                  ),
                                  small: true,
                                  secondary: true,
                                  onPressed:
                                      working || widget.controller.installing
                                      ? null
                                      : () => install(release),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (hasMore && !loading)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: AppButton(
                      '加载更多版本',
                      secondary: true,
                      onPressed: () => load(next: true),
                    ),
                  ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class PackChoices {
  final String name;
  final bool isolated;
  final Set<String> optional;
  const PackChoices(this.name, this.isolated, this.optional);
}

class DataPackWorldDialog extends StatefulWidget {
  final List<Directory> worlds;
  const DataPackWorldDialog({required this.worlds, super.key});
  @override
  State<DataPackWorldDialog> createState() => _DataPackWorldDialogState();
}

class _DataPackWorldDialogState extends State<DataPackWorldDialog> {
  late String selected = widget.worlds.first.path;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择存档'),
    content: SizedBox(
      width: 420,
      child: SelectBox<String>(
        value: selected,
        items: {
          for (final world in widget.worlds) world.path: p.basename(world.path),
        },
        onChanged: (value) => setState(() => selected = value),
      ),
    ),
    actions: [
      AppButton('取消', secondary: true, onPressed: () => Navigator.pop(context)),
      AppButton('继续', onPressed: () => Navigator.pop(context, selected)),
    ],
  );
}

class PackInstallDialog extends StatefulWidget {
  final PackPlan plan;
  final ContentVersion release;
  final bool isolated;
  const PackInstallDialog({
    required this.plan,
    required this.release,
    required this.isolated,
    super.key,
  });
  @override
  State<PackInstallDialog> createState() => _PackInstallDialogState();
}

class _PackInstallDialogState extends State<PackInstallDialog> {
  late final name = TextEditingController(
    text: '${widget.plan.name} ${widget.plan.version}'.trim(),
  );
  late bool isolated = widget.isolated;
  final optional = <String>{};
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final plan = widget.plan;
    return AlertDialog(
      title: const Text('安装整合包', style: TextStyle(fontSize: 19)),
      content: SizedBox(
        width: 500,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .6,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  plan.name,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '发布版本：${widget.release.name}\nMinecraft：${plan.minecraft}\n加载器：${plan.loader?.label ?? '原版'} ${plan.loaderVersion ?? ''}\n文件：${plan.files.length} 项',
                  style: TextStyle(
                    color: c.secondaryText,
                    fontSize: 14,
                    height: 1.6,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 16),
                AppInput(controller: name, label: '版本名称'),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用版本隔离', style: TextStyle(fontSize: 12)),
                  value: isolated,
                  onChanged: (v) => setState(() => isolated = v ?? true),
                ),
                if (!isolated)
                  Text(
                    '模组和配置将写入游戏根目录，与其他未隔离版本共用。',
                    style: TextStyle(color: c.muted, fontSize: 11),
                  ),
                if (plan.files.any((f) => f.optional)) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '可选文件',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  for (final file in plan.files.where((f) => f.optional))
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        file.path.isEmpty
                            ? '项目 ${file.projectId} · 文件 ${file.fileId}'
                            : file.path,
                        style: const TextStyle(fontSize: 11),
                      ),
                      value: optional.contains(
                        file.path.isEmpty
                            ? '${file.projectId}:${file.fileId}'
                            : file.path,
                      ),
                      onChanged: (v) => setState(() {
                        final key = file.path.isEmpty
                            ? '${file.projectId}:${file.fileId}'
                            : file.path;
                        if (v == true) {
                          optional.add(key);
                        } else {
                          optional.remove(key);
                        }
                      }),
                    ),
                ],
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(color: Colors.red.shade400, fontSize: 12),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        AppButton(
          '取消',
          secondary: true,
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          '开始安装',
          onPressed: () {
            final invalidName = validateVersionName(name.text.trim());
            if (invalidName != null) {
              setState(() => error = invalidName);
              return;
            }
            Navigator.pop(
              context,
              PackChoices(name.text.trim(), isolated, optional),
            );
          },
        ),
      ],
    );
  }
}
