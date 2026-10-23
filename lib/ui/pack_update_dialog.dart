import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/community_catalog.dart';
import '../core/community_models.dart';
import '../core/controller.dart';
import '../core/local_pack.dart';
import '../core/models.dart';
import '../core/network.dart';
import '../core/pack_import.dart';
import '../core/pack_updates.dart';
import '../core/pack_origin.dart';
import '../l10n/app_localizations.dart';
import 'content_tasks.dart';
import 'theme.dart';

class PackUpdateDialog extends StatefulWidget {
  final LauncherController controller;
  final GameInstance instance;
  final ContentTask? existingTask;
  const PackUpdateDialog({
    required this.controller,
    required this.instance,
    this.existingTask,
    super.key,
  });
  @override
  State<PackUpdateDialog> createState() => _PackUpdateDialogState();
}

class _PackUpdateDialogState extends State<PackUpdateDialog> {
  CancellationToken token = CancellationToken();
  final name = TextEditingController();
  final projectReference = TextEditingController();
  late final CommunityCatalog catalog;
  Json? record;
  ContentProject? project;
  ContentVersion? selected;
  final versions = <ContentVersion>[];
  PackPlan? plan;
  ContentTask? task;
  PackUpdatePreview? preview;
  final incoming = <String>{}, optional = <String>{};
  bool busy = true, keepOriginal = false, previews = false, more = false;
  int page = 0;
  String? error;
  String notes = '';
  DateTime? currentPublished;
  ContentSource bindingSource = ContentSource.modrinth;
  bool localOnly = false;
  String? sourceNotice;

  @override
  void initState() {
    super.initState();
    catalog = widget.controller.communityCatalogFactory(
      widget.controller.settings.copy(),
    );
    unawaited(load());
  }

  @override
  void dispose() {
    token.cancel();
    catalog.close();
    name.dispose();
    projectReference.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() operation) async {
    if (token.cancelled) token = CancellationToken();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted && e is! Cancelled) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() => run(() async {
    record = await readPackRecord(widget.instance);
    bindingSource =
        ContentSource.values
            .where((source) => source.name == record!['source'])
            .firstOrNull ??
        ContentSource.modrinth;
    optional.addAll((record!['optional'] as List? ?? []).cast<String>());
    if (widget.existingTask != null) {
      task = widget.existingTask;
      project = task!.updateProject;
      selected = task!.updateRelease;
      plan = await inspectModpack(task!.updateArchive!);
      name.text = '${widget.instance.name} - ${plan!.version}';
      await preparePreview();
      return;
    }
    localOnly = !hasOnlinePackOrigin(record!);
    sourceNotice = null;
    PackOriginMatch? identified;
    if (localOnly) {
      try {
        final match = await identifyImportedPack(
          record!,
          widget.controller.supportDirectory,
          catalog,
          token,
        );
        token.check();
        if (match != null) {
          identified = match;
          record = await widget.controller.linkPackProject(
            widget.instance.id,
            match.project,
            installed: match.version,
          );
          localOnly = false;
        }
      } on Cancelled {
        rethrow;
      } catch (error) {
        sourceNotice = '自动识别来源失败：$error';
      }
      if (localOnly) return;
    }
    await loadOnlineVersions(
      resolved: identified?.project,
      installed: identified?.version,
    );
  });

  Future<void> loadOnlineVersions({
    ContentProject? resolved,
    ContentVersion? installed,
  }) async {
    final projectId = record!['projectId'] as String;
    final source = ContentSource.values.byName(record!['source'] as String);
    project =
        resolved ??
        await catalog.project(source, projectId, ContentKind.modpack, token);
    currentPublished =
        installed?.id == record!['releaseId'] &&
            installed?.projectId == projectId
        ? installed?.published
        : null;
    if (currentPublished == null &&
        (record!['releaseId'] as String? ?? '').isNotEmpty) {
      try {
        currentPublished = (await catalog.version(
          source,
          projectId,
          record!['releaseId'] as String,
          token,
        )).published;
      } catch (_) {
        token.check();
        /* Unknown versions must be chosen explicitly. */
      }
    }
    versions.clear();
    page = 0;
    more = false;
    selected = null;
    notes = '';
    plan = null;
    await loadPage();
  }

  Future<void> link() => run(() async {
    final reference = parsePackProjectReference(
      bindingSource,
      projectReference.text,
    );
    final resolved = await resolvePackProject(catalog, reference, token);
    token.check();
    record = await widget.controller.linkPackProject(
      widget.instance.id,
      resolved,
    );
    localOnly = false;
    sourceNotice = null;
    bindingSource = resolved.source;
    await loadOnlineVersions(resolved: resolved);
  });

  Future<void> loadPage() async {
    final result = await catalog.versions(project!, token, page: page);
    final ids = versions.map((version) => version.id).toSet();
    versions.addAll(result.versions.where((version) => ids.add(version.id)));
    more = result.hasMore;
    page++;
    if (selected == null) {
      selected = versions
          .where(
            (version) =>
                version.releaseType == 'release' &&
                version.id != record?['releaseId'] &&
                currentPublished != null &&
                version.published.isAfter(currentPublished!),
          )
          .firstOrNull;
      if (selected != null) await select(selected!);
    }
  }

  Future<void> select(ContentVersion value) async {
    selected = value;
    plan = null;
    name.text = '${widget.instance.name} - ${value.number}';
    notes = '';
    try {
      notes = await catalog.versionNotes(value, token);
    } catch (_) {
      notes = tr('无法获取更新日志。');
    }
  }

  Future<void> local() => run(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: tr('整合包'), extensions: ['mrpack', 'zip']),
      ],
    );
    if (file == null) return;
    final result = await stageLocalPack(
      file.path,
      widget.controller.supportDirectory,
    );
    plan = result.$1;
    project = result.$2;
    selected = result.$3;
    versions.clear();
    more = false;
    notes = '';
    name.text = '${widget.instance.name} - ${plan!.version}';
  });

  Future<void> prepare() => run(() async {
    widget.controller.editableInstance(widget.instance.id);
    if (task == null) {
      if (plan == null) {
        plan = await widget.controller.content.preparePack(
          project!,
          selected!,
          token,
        );
        // Allow choosing optional files before downloading the complete pack.
        if (plan!.files.any((entry) => entry.optional)) return;
      }
      task = await widget.controller.content.installPack(
        project!,
        selected!,
        plan!,
        'FYL-update-${DateTime.now().microsecondsSinceEpoch}',
        isolated: true,
        registerInstance: false,
        gameRoot: widget.instance.root,
        optional: optional,
        onStarted: (value) {
          value.updateTargetId = widget.instance.id;
          value.updateArchive = plan!.archive;
          value.updateProject = project;
          value.updateRelease = selected;
          if (mounted) setState(() => task = value);
        },
      );
    }
    if (!mounted) return;
    await preparePreview();
  });

  Future<void> preparePreview() async {
    if (task!.state != ContentTaskState.completed ||
        task!.preparedInstance == null) {
      return;
    }
    preview = await previewPackUpdate(
      widget.instance,
      task!.preparedInstance!,
      supportDirectory: widget.controller.supportDirectory,
    );
    token.check();
    final previous = record;
    keepOriginal =
        !widget.instance.isolated ||
        preview!.unknownBaseline ||
        widget.instance.version != plan!.minecraft ||
        previous?['loader'] != plan!.loader?.name;
    task!.stage = '等待确认升级';
    widget.controller.notifyListeners();
  }

  Future<void> apply() => run(() async {
    await widget.controller.applyPackUpdate(
      preview!,
      incoming,
      task!,
      keepOriginal: keepOriginal,
      copyName: name.text,
    );
    if (mounted) Navigator.pop(context, true);
  });

  Future<void> close() => run(() async {
    if (task != null) {
      if (task!.preparedInstance == null) {
        widget.controller.content.cancel(task!);
        task!.canRetry = false;
      } else {
        await widget.controller.discardPackUpdate(task!);
      }
    }
    if (mounted) Navigator.pop(context);
  });

  Widget sourceControls() => SizedBox(
    width: double.infinity,
    child: Surface(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LText(
            hasOnlinePackOrigin(record!) ? '更改整合包在线来源' : '本地导入的整合包尚未关联在线项目。',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 7),
          const LText('关联来源后可检查在线版本，也可选择新版整合包文件更新。'),
          const SizedBox(height: 14),
          SelectBox<ContentSource>(
            value: bindingSource,
            items: {
              for (final source in ContentSource.values) source: source.label,
            },
            onChanged: busy
                ? null
                : (value) => setState(() => bindingSource = value),
          ),
          const SizedBox(height: 10),
          AppInput(
            key: const ValueKey('pack-update-project-reference'),
            controller: projectReference,
            label: '整合包项目链接或 ID',
            enabled: !busy,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppButton('关联并检查更新', small: true, onPressed: busy ? null : link),
              AppButton(
                hasOnlinePackOrigin(record!) ? '取消' : '重新识别',
                small: true,
                secondary: true,
                onPressed: busy
                    ? null
                    : () {
                        if (hasOnlinePackOrigin(record!)) {
                          unawaited(
                            run(() async {
                              localOnly = false;
                              await loadOnlineVersions();
                            }),
                          );
                        } else {
                          unawaited(load());
                        }
                      },
              ),
            ],
          ),
          if (sourceNotice != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: LText(
                sourceNotice!,
                style: TextStyle(
                  color: LauncherColors.of(context).muted,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget versionControls() {
    if (localOnly && plan == null) return sourceControls();
    if (project == null || localOnly) return const SizedBox.shrink();
    final visible = versions
        .where((version) => previews || version.releaseType == 'release')
        .toList();
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${project!.source.label} · ${project!.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        bindingSource = project!.source;
                        projectReference.text = project!.website;
                        localOnly = true;
                        selected = null;
                        plan = null;
                        notes = '';
                      }),
                child: const LText('更改来源'),
              ),
            ],
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const LText('显示测试版'),
            value: previews,
            onChanged: busy
                ? null
                : (value) => setState(() => previews = value!),
          ),
          if (!busy && versions.isEmpty) const LText('该项目暂无可用的整合包版本。'),
          if (!busy && versions.isNotEmpty && visible.isEmpty)
            const LText('暂无正式版，可开启“显示测试版”查看其他版本。'),
          if (visible.isNotEmpty) ...[
            const LText('目标版本'),
            const SizedBox(height: 7),
            SelectBox<String>(
              key: const ValueKey('pack-update-version'),
              value: selected?.id ?? '',
              localizeItems: false,
              items: {
                '': tr('选择版本'),
                for (final version in visible)
                  version.id:
                      '${version.number} · ${version.gameVersions.join(', ')} · ${version.releaseType}',
              },
              onChanged: busy
                  ? null
                  : (value) {
                      if (value.isEmpty) {
                        setState(() {
                          selected = null;
                          notes = '';
                          plan = null;
                        });
                        return;
                      }
                      unawaited(
                        run(
                          () => select(
                            versions.firstWhere(
                              (version) => version.id == value,
                            ),
                          ),
                        ),
                      );
                    },
            ),
          ],
          if (more)
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                '加载更多',
                small: true,
                secondary: true,
                onPressed: busy ? null : () => run(loadPage),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const LText('整合包升级'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height - 240)
                .clamp(180, 520)
                .toDouble(),
          ),
          child: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.instance.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (record != null) LText('当前版本：${record!['version']}'),
                  const SizedBox(height: 12),
                  if (busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 10),
                    LText(localOnly ? '正在识别整合包来源…' : '正在检查整合包更新…'),
                    const SizedBox(height: 12),
                  ],
                  if (task == null && preview == null) ...[
                    versionControls(),
                    const SizedBox(height: 12),
                    AppButton(
                      '从文件更新',
                      secondary: true,
                      onPressed: busy ? null : local,
                    ),
                    if (notes.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(notes),
                      ),
                    if (plan != null) ...[
                      LText(
                        '目标版本：${plan!.version} · Minecraft ${plan!.minecraft}',
                      ),
                      for (final entry in plan!.files.where(
                        (entry) => entry.optional,
                      ))
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            entry.path.isEmpty
                                ? '${entry.projectId}:${entry.fileId}'
                                : entry.path,
                          ),
                          value: optional.contains(
                            entry.path.isEmpty
                                ? '${entry.projectId}:${entry.fileId}'
                                : entry.path,
                          ),
                          onChanged: busy
                              ? null
                              : (value) => setState(() {
                                  final id = entry.path.isEmpty
                                      ? '${entry.projectId}:${entry.fileId}'
                                      : entry.path;
                                  if (value!) {
                                    optional.add(id);
                                  } else {
                                    optional.remove(id);
                                  }
                                }),
                        ),
                    ],
                  ],
                  if (task != null && preview == null)
                    ContentTaskCard(
                      controller: widget.controller,
                      task: task!,
                      allowPackUpdate: false,
                    ),
                  if (preview != null) ...[
                    if (preview!.unknownBaseline)
                      const LText('部分旧文件缺少安装基线，请检查冲突；建议升级到副本。'),
                    if (widget.instance.version != plan!.minecraft)
                      const LText('Minecraft 版本发生变化，建议保留原版本并使用副本。'),
                    if (currentPublished != null &&
                        selected!.published.isBefore(currentPublished!))
                      const LText('所选版本早于当前版本，降级可能导致存档或配置不兼容。'),
                    LText('${record?['version']} → ${plan!.version}'),
                    LText(
                      '新增 ${preview!.added}，替换 ${preview!.replaced}，移除 ${preview!.deleted}，冲突 ${preview!.conflicts.length}',
                    ),
                    const SizedBox(height: 8),
                    const LText('存档和个人设置会保留。勾选冲突文件表示使用整合包新版文件。'),
                    for (final path in preview!.conflicts.toList()..sort())
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(path),
                        value: incoming.contains(path),
                        onChanged: busy
                            ? null
                            : (value) => setState(() {
                                if (value!) {
                                  incoming.add(path);
                                } else {
                                  incoming.remove(path);
                                }
                              }),
                      ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const LText('保留原版本，升级到新副本'),
                      value: keepOriginal,
                      onChanged: busy || !widget.instance.isolated
                          ? null
                          : (value) => setState(() => keepOriginal = value!),
                    ),
                    if (keepOriginal)
                      TextField(
                        controller: name,
                        decoration: InputDecoration(labelText: tr('副本名称')),
                      ),
                    if (!keepOriginal) const LText('升级前的完整版本会保留，可在版本设置中还原。'),
                  ],
                  if (error != null)
                    LText(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          if (task != null && preview == null)
            AppButton(
              '后台准备',
              secondary: true,
              onPressed: () => Navigator.pop(context),
            ),
          if (busy)
            AppButton(
              '取消任务',
              secondary: true,
              onPressed: () {
                token.cancel();
                task?.token.cancel();
              },
            ),
          AppButton('关闭', secondary: true, onPressed: busy ? null : close),
          if (preview != null)
            AppButton('确认升级', onPressed: busy || !task!.canRetry ? null : apply)
          else
            AppButton(
              task == null ? '下载并预览' : '继续预览升级',
              onPressed:
                  busy ||
                      selected == null ||
                      task != null && task!.state != ContentTaskState.completed
                  ? null
                  : prepare,
            ),
        ],
      ),
    ),
  );
}
