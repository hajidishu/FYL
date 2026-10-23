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
  final token = CancellationToken();
  final name = TextEditingController();
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
    super.dispose();
  }

  Future<void> run(Future<void> Function() operation) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() => run(() async {
    record = await readPackRecord(widget.instance);
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
    final projectId = record!['projectId'] as String? ?? '';
    if (projectId.isEmpty || projectId.startsWith('local-')) return;
    final source = ContentSource.values.byName(record!['source'] as String);
    project = await catalog.project(
      source,
      projectId,
      ContentKind.modpack,
      token,
    );
    try {
      currentPublished = (await catalog.version(
        source,
        projectId,
        record!['releaseId'] as String,
        token,
      )).published;
    } catch (_) {
      /* Unknown versions must be chosen explicitly. */
    }
    await loadPage();
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const LText('整合包升级'),
        content: SizedBox(
          width: 720,
          height: 470,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.instance.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (record != null) LText('当前版本：${record!['version']}'),
                const SizedBox(height: 12),
                if (busy) const LinearProgressIndicator(),
                if (task == null && preview == null) ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const LText('显示测试版'),
                    value: previews,
                    onChanged: busy
                        ? null
                        : (value) => setState(() => previews = value!),
                  ),
                  if (versions.isNotEmpty)
                    SelectBox<String>(
                      value: selected?.id ?? '',
                      items: {
                        for (final version in versions)
                          if (previews || version.releaseType == 'release')
                            version.id:
                                '${version.number} · ${version.gameVersions.join(', ')} · ${version.releaseType}',
                      },
                      onChanged: busy
                          ? null
                          : (value) => run(
                              () => select(
                                versions.firstWhere(
                                  (version) => version.id == value,
                                ),
                              ),
                            ),
                    ),
                  if (more)
                    AppButton(
                      '加载更多',
                      secondary: true,
                      onPressed: busy ? null : () => run(loadPage),
                    ),
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
