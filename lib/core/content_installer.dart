import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'community_catalog.dart';
import 'community_models.dart';
import 'install_options.dart';
import 'minecraft.dart';
import 'mod_catalog.dart';
import 'models.dart';
import 'network.dart';
import 'pack_import.dart';
import 'instance_tools.dart' show isGameDataPath;
import 'file_transaction.dart';
import 'resource_packs.dart';
import 'game_options.dart';
import 'install_worker.dart';
import 'pack_updates.dart';

typedef ContentCatalogFactory = CommunityCatalog Function(LauncherSettings);
typedef PackBaseInstaller =
    Future<GameInstance> Function(
      InstallTask,
      CancellationToken,
      void Function(),
    );

class _PackSession {
  final ContentProject project;
  final ContentVersion release;
  final PackPlan plan;
  final String name;
  final LauncherSettings settings;
  final Set<String> optional;
  final bool registerInstance;
  List<(ContentFile, String)>? files;
  GameInstance? baseInstance;
  _PackSession(
    this.project,
    this.release,
    this.plan,
    this.name,
    this.settings,
    this.optional,
    this.registerInstance,
  );
}

class _ModSession {
  final ContentProject project;
  final ContentVersion release;
  final GameInstance target;
  final String destination;
  final bool dependencies;
  List<(ContentFile, String)>? files;
  _ModSession(
    this.project,
    this.release,
    this.target,
    this.destination,
    this.dependencies,
  );
}

class ContentInstaller {
  final HostPlatform platform;
  final String supportDirectory;
  final LauncherSettings Function() settings;
  final void Function() onChanged;
  final Future<void> Function(GameInstance) onInstalled;
  final Future<void> Function(ContentTask)? onPreparedPackUpdate;
  final bool Function() busy;
  final ContentCatalogFactory catalogFactory;
  final PackBaseInstaller? installBase;
  final void Function(GameInstance)? checkModTarget;
  final void Function(String, bool)? checkPackTarget;
  final bool Function(String)? versionInUse;
  final tasks = <ContentTask>[];
  final _packs = <String, _PackSession>{};
  final _mods = <String, _ModSession>{};
  final _missingTargets = <String, List<(ContentFile, String)>>{};
  final _archiveTransfers = <String, (int, int)>{};
  ContentInstaller({
    required this.platform,
    required this.supportDirectory,
    required this.settings,
    required this.onChanged,
    required this.onInstalled,
    this.onPreparedPackUpdate,
    required this.busy,
    ContentCatalogFactory? catalogFactory,
    this.installBase,
    this.checkModTarget,
    this.checkPackTarget,
    this.versionInUse,
  }) : catalogFactory = catalogFactory ?? CommunityCatalog.new;

  String _cache(String key) => p.join(
    supportDirectory,
    'cache',
    'community',
    sha256.convert(utf8.encode(key)).toString(),
  );
  void _checkBusy() {
    if (busy()) throw StateError('请等待当前下载完成，或先取消当前任务。');
  }

  Future<PackPlan> preparePack(
    ContentProject project,
    ContentVersion release,
    CancellationToken token, {
    String? localPath,
  }) async {
    final file = release.files
        .where((f) => f.name.endsWith('.mrpack') || f.name.endsWith('.zip'))
        .firstOrNull;
    if (file == null) throw StateError('此发布版本没有受支持的整合包文件。');
    final archive = p.join(
      _cache('${project.source.name}:${project.id}:${release.id}'),
      contentFileName(file.name),
    );
    final catalog = catalogFactory(settings());
    var transferred = 0, reused = 0;
    try {
      if (localPath == null) {
        await catalog.network.download(
          file.download(archive),
          token,
          onBytes: (count) => transferred += count,
          onCachedBytes: (count) => reused += count,
        );
      } else {
        if (!await file.matches(File(localPath))) {
          throw const FormatException('所选整合包文件与发布版本不匹配。');
        }
        await File(archive).parent.create(recursive: true);
        if (p.normalize(localPath) != p.normalize(archive)) {
          await File(localPath).copy(archive);
        }
        reused = await File(archive).length();
      }
      token.check();
      final plan = await inspectModpack(archive);
      _archiveTransfers[plan.archive] = (transferred, reused);
      return plan;
    } finally {
      catalog.close();
    }
  }

  Future<ContentTask> installMod(
    ContentProject project,
    ContentVersion release,
    GameInstance target,
    String destination, {
    bool dependencies = true,
    void Function(ContentTask)? onStarted,
  }) async {
    _checkBusy();
    checkModTarget?.call(target);
    if (project.kind != ContentKind.mod && !project.kind.isResource) {
      throw ArgumentError('此资源需要使用整合包安装流程。');
    }
    if (project.kind.isResource) {
      resourceFile(project, release, target);
      if (!destination.toLowerCase().endsWith('.zip')) {
        throw ArgumentError('资源文件应保存为 ZIP。');
      }
    }
    final task = ContentTask(project.name, project.kind, project.source)
      ..destination = destination;
    tasks.insert(0, task);
    _mods[task.id] = _ModSession(
      project,
      release,
      target,
      destination,
      dependencies,
    );
    onChanged();
    onStarted?.call(task);
    await _run(task);
    return task;
  }

  Future<ContentTask> installResource(
    ContentProject project,
    ContentVersion release,
    GameInstance target,
    String destination, {
    void Function(ContentTask)? onStarted,
  }) {
    if (!project.kind.isResource) throw ArgumentError('请选择数据包、资源包或光影包。');
    return installMod(
      project,
      release,
      target,
      destination,
      dependencies: false,
      onStarted: onStarted,
    );
  }

  Future<ContentTask> installPack(
    ContentProject project,
    ContentVersion release,
    PackPlan plan,
    String name, {
    required bool isolated,
    Set<String> optional = const {},
    bool registerInstance = true,
    String? gameRoot,
    void Function(ContentTask)? onStarted,
  }) async {
    _checkBusy();
    final normalizedName = name.trim();
    final nameError = validateVersionName(normalizedName);
    if (nameError != null) throw ArgumentError(nameError);
    final snapshot = settings()..isolateVersions = isolated;
    if (gameRoot != null) snapshot.gameRoot = gameRoot;
    final error = snapshot.validate();
    if (error != null) throw ArgumentError(error);
    final directory = safeJoin(
      p.join(snapshot.gameRoot, 'versions'),
      normalizedName,
    );
    if (versionInUse?.call(directory) == true ||
        await FileSystemEntity.type(directory, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError('版本名称“$normalizedName”已存在，请使用其他名称。');
    }
    final archiveTransfer = _archiveTransfers.remove(plan.archive);
    final localArchiveBytes =
        archiveTransfer == null && await File(plan.archive).exists()
        ? await File(plan.archive).length()
        : 0;
    _checkBusy();
    checkPackTarget?.call(snapshot.gameRoot, isolated);
    final task =
        ContentTask(normalizedName, ContentKind.modpack, project.source)
          ..bytes = archiveTransfer?.$1 ?? 0
          ..cachedBytes = archiveTransfer?.$2 ?? localArchiveBytes;
    tasks.insert(0, task);
    _packs[task.id] = _PackSession(
      project,
      release,
      plan,
      normalizedName,
      snapshot,
      optional,
      registerInstance,
    );
    onChanged();
    onStarted?.call(task);
    await _run(task);
    return task;
  }

  Future<void> retry(ContentTask task) async {
    _checkBusy();
    if (task.state == ContentTaskState.completed) {
      throw StateError('此任务已经完成，无需重试。');
    }
    final mod = _mods[task.id];
    if (mod != null) checkModTarget?.call(mod.target);
    final pack = _packs[task.id];
    if (pack != null) {
      checkPackTarget?.call(
        pack.settings.gameRoot,
        pack.settings.isolateVersions,
      );
    }
    task.token = CancellationToken();
    task.state = ContentTaskState.running;
    task.error = null;
    onChanged();
    await _run(task);
  }

  void cancel(ContentTask task) {
    task.token.cancel();
    if (task.state == ContentTaskState.waiting) {
      task.state = ContentTaskState.cancelled;
      task.stage = '已取消';
    }
    onChanged();
  }

  bool dismiss(ContentTask task) {
    if (task.preparedInstance != null ||
        task.state == ContentTaskState.running ||
        task.state == ContentTaskState.waiting) {
      return false;
    }
    if (!tasks.remove(task)) return false;
    _packs.remove(task.id);
    _mods.remove(task.id);
    _missingTargets.remove(task.id);
    onChanged();
    return true;
  }

  void dispose() {
    for (final task in tasks) {
      task.token.cancel();
    }
  }

  Future<int> supplyFiles(ContentTask task, List<String> paths) async {
    var matched = 0;
    for (final (expected, target)
        in _missingTargets[task.id] ?? <(ContentFile, String)>[]) {
      for (final path in paths) {
        final source = File(path);
        if ((expected.hashes.isNotEmpty || p.basename(path) == expected.name) &&
            await expected.matches(source)) {
          await File(target).parent.create(recursive: true);
          if (p.normalize(source.path) != p.normalize(target)) {
            await source.copy(target);
          }
          matched++;
          break;
        }
      }
    }
    if (matched == 0) throw const FormatException('所选文件与缺失清单不匹配，请检查版本。');
    await retry(task);
    return matched;
  }

  Future<void> _run(ContentTask task) async {
    // Archive preparation and earlier attempts are already included in bytes,
    // but only this attempt's live transfers belong in the current speed.
    task.downloadRate.reset();
    final snapshot = settings();
    final catalog = catalogFactory(snapshot);
    try {
      if (_packs.containsKey(task.id)) {
        await _pack(task, _packs[task.id]!, catalog);
      } else {
        await _mod(task, _mods[task.id]!, catalog);
      }
    } on Cancelled {
      task.state = ContentTaskState.cancelled;
      task.stage = '已取消';
    } catch (e) {
      task.state = ContentTaskState.failed;
      task.stage = '安装失败';
      task.error = '$e'.replaceAll(
        snapshot.curseforgeApiKey.isEmpty
            ? '\u0000'
            : snapshot.curseforgeApiKey,
        '[已隐藏密钥]',
      );
    } finally {
      catalog.close();
      onChanged();
    }
  }

  void _stage(ContentTask task, String stage) {
    task.token.check();
    task.stage = stage;
    task.done = 0;
    task.total = 0;
    onChanged();
  }

  Future<bool> _downloadFiles(
    ContentTask task,
    List<(ContentFile, String)> files,
    CommunityCatalog catalog,
  ) async {
    _stage(task, '下载${task.kind.label}文件');
    final downloads = <DownloadFile>[];
    final missing = <(ContentFile, String)>[];
    task.total = files.length;
    for (final (file, path) in files) {
      task.token.check();
      if (file.urls.isNotEmpty) {
        downloads.add(file.download(path));
      } else if (await file.matches(File(path))) {
        task.done++;
        task.cachedBytes += await File(path).length();
        onChanged();
      } else {
        missing.add((file, path));
      }
    }
    final already = task.done;
    await catalog.network.downloadAll(
      downloads,
      task.token,
      onProgress: (done, _, path) {
        task.done = already + done;
        task.detail = p.basename(path);
        onChanged();
      },
      onBytes: (count) {
        task.bytes += count;
        onChanged();
      },
      onCachedBytes: (count) {
        task.cachedBytes += count;
        onChanged();
      },
    );
    task.missing = missing.map((e) => e.$1).toList();
    _missingTargets[task.id] = missing;
    if (missing.isNotEmpty) {
      task.state = ContentTaskState.waiting;
      task.stage = '等待补齐文件';
      onChanged();
      return false;
    }
    return true;
  }

  Future<void> _mod(
    ContentTask task,
    _ModSession session,
    CommunityCatalog catalog,
  ) async {
    final kind = session.project.kind;
    _stage(task, kind.isResource ? '准备${kind.label}' : '解析模组依赖');
    if (session.files == null) {
      final files = kind.isResource
          ? [resourceFile(session.project, session.release, session.target)]
          : await catalog.modFiles(
              session.project,
              session.release,
              session.target,
              task.token,
              dependencies: session.dependencies,
            );
      final cache = _cache(
        '${kind.name}:${session.project.source.name}:${session.release.id}',
      );
      session.files = [
        for (var i = 0; i < files.length; i++)
          (files[i], p.join(cache, '$i-${contentFileName(files[i].name)}')),
      ];
      for (var i = 0; i < session.files!.length; i++) {
        final file = session.files![i].$1;
        if (file.urls.isEmpty && file.website.isEmpty) {
          final info = await catalog.project(
            session.project.source,
            file.projectId,
            kind,
            task.token,
          );
          session.files![i] = (
            file.withWebsite('${info.website}/files/${file.id}'),
            session.files![i].$2,
          );
        }
      }
    }
    if (!await _downloadFiles(task, session.files!, catalog)) return;
    if (kind.isResource) {
      await validateResourceArchive(session.files!.first.$2, kind);
    }
    task.token.check();
    _stage(task, kind == ContentKind.mod ? '安装模组' : '安装${kind.label}');
    final folder = p.dirname(session.destination);
    final destinations = <String>{};
    for (var i = 0; i < session.files!.length; i++) {
      final file = session.files![i].$1;
      final target = i == 0
          ? session.destination
          : p.join(folder, contentFileName(file.name));
      if (!destinations.add(p.normalize(target).toLowerCase())) {
        throw const FormatException('模组及依赖文件的保存路径冲突。');
      }
      await ensurePackParents(folder, target);
    }
    final indexPath = File(
      p.join(
        folder,
        kind == ContentKind.mod
            ? '.fyl-managed-mods.json'
            : '.fyl-managed-${kind.name}.json',
      ),
    );
    Json index = {};
    try {
      index = jsonDecode(await indexPath.readAsString()) as Json;
    } catch (_) {}
    final copies = <(String, String)>[];
    final removals = <String>{};
    for (var i = 0; i < session.files!.length; i++) {
      task.token.check();
      final (file, cached) = session.files![i];
      final target = i == 0
          ? session.destination
          : p.join(folder, contentFileName(file.name));
      copies.add((cached, target));
      final key = '${session.project.source.name}:${file.projectId}';
      final old = index[key] as Json?;
      final oldName = old?['path'] as String?;
      final oldPath = oldName != null && p.basename(oldName) == oldName
          ? p.join(folder, oldName)
          : null;
      if (oldPath != null && oldPath != target && p.isWithin(folder, oldPath)) {
        final oldHash = old?['sha1'] as String?;
        final oldFile = File(oldPath);
        if (oldHash != null &&
            await oldFile.exists() &&
            (await sha1.bind(oldFile.openRead()).first).toString() == oldHash) {
          removals.add(oldPath);
        }
      }
      index[key] = {
        'path': p.basename(target),
        'version': file.id,
        'sha1': (await sha1.bind(File(cached).openRead()).first).toString(),
      };
    }
    final stagedIndex = File(
      p.join(_cache('mod-index:${task.id}'), 'installed.json'),
    );
    await writeJson(stagedIndex, index);
    copies.add((stagedIndex.path, indexPath.path));
    await publishFiles(
      folder,
      copies,
      task.token,
      removals: removals
          .where(
            (path) => !destinations.contains(p.normalize(path).toLowerCase()),
          )
          .toList(),
      onProgress: (done, total) {
        task.done = done;
        task.total = total;
        onChanged();
      },
    );
    task.state = ContentTaskState.completed;
    task.stage = '安装完成';
    task.destination = session.destination;
  }

  Future<void> _pack(
    ContentTask task,
    _PackSession session,
    CommunityCatalog catalog,
  ) async {
    _stage(task, '解析整合包文件');
    final plan = session.plan;
    if (session.files == null) {
      final files = <(ContentFile, String)>[];
      final destinations = <String>{};
      final cache = _cache(
        'pack-files:${session.project.source.name}:${session.release.id}',
      );
      for (final entry in plan.files) {
        task.token.check();
        final id = entry.path.isEmpty
            ? '${entry.projectId}:${entry.fileId}'
            : entry.path;
        if (entry.optional && !session.optional.contains(id)) continue;
        final file =
            entry.file ??
            await catalog.curseFile(
              entry.projectId!,
              entry.fileId!,
              task.token,
            );
        final relative = entry.path.isEmpty
            ? 'mods/${contentFileName(file.name)}'
            : entry.path;
        if (!destinations.add(relative.toLowerCase())) {
          throw FormatException('整合包文件路径冲突：$relative');
        }
        if (plan.overrides.containsKey(relative)) continue;
        files.add((file, safeJoin(p.join(cache, 'files'), relative)));
      }
      session.files = files;
    }
    if (!await _downloadFiles(task, session.files!, catalog)) return;
    _stage(task, '准备游戏与加载器');
    final manifest = await catalog.network.json(
      versionManifestUrl,
      token: task.token,
    );
    final raw = (manifest['versions'] as List)
        .cast<Json>()
        .where((v) => v['id'] == plan.minecraft)
        .firstOrNull;
    if (raw == null) {
      throw StateError('官方版本清单中不存在 Minecraft ${plan.minecraft}。');
    }
    var options = const InstallOptions();
    if (plan.loader != null) {
      final versions = await ModCatalog(
        catalog.network,
      ).loaders(plan.loader!, plan.minecraft, task.token);
      final selected = versions
          .where(
            (v) =>
                v.version == plan.loaderVersion ||
                v.coordinate.split(':').last == plan.loaderVersion ||
                '${plan.minecraft}-${v.version}' == plan.loaderVersion,
          )
          .firstOrNull;
      if (selected == null) {
        throw StateError(
          '找不到指定加载器 ${plan.loader!.label} ${plan.loaderVersion}。',
        );
      }
      options = InstallOptions(loader: selected);
    }
    final install = InstallTask(
      MinecraftVersion.fromJson(raw),
      session.name,
      session.settings.copy()..autoChinese = false,
      options: options,
    );
    var transferredBase = 0, reusedBase = 0;
    void update() {
      task.bytes += (install.downloadedBytes - transferredBase).clamp(
        0,
        install.downloadedBytes,
      );
      task.cachedBytes += (install.cachedBytes - reusedBase).clamp(
        0,
        install.cachedBytes,
      );
      transferredBase = install.downloadedBytes;
      reusedBase = install.cachedBytes;
      task.stage = install.stage;
      task.detail = install.detail;
      task.done = install.completedFiles;
      task.total = install.totalFiles;
      onChanged();
    }

    var instance = session.baseInstance;
    if (instance == null) {
      try {
        instance = installBase == null
            ? await runInstallerWorker(
                platform,
                install,
                null,
                task.token,
                onProgress: (progress) {
                  progress.apply(install);
                  update();
                },
              )
            : await installBase!(install, task.token, update);
        session.baseInstance = instance;
      } finally {
        update();
      }
    }
    try {
      _stage(task, '应用整合包配置');
      final cacheRoot = p.join(
        _cache(
          'pack-files:${session.project.source.name}:${session.release.id}',
        ),
        'files',
      );
      bool isOptions(String relative) =>
          relative.replaceAll('\\', '/').toLowerCase() == 'options.txt';
      for (final relative in [
        ...plan.overrides.keys,
        for (final (_, cached) in session.files!)
          p.relative(cached, from: cacheRoot),
      ]) {
        if (!isGameDataPath(relative, instance)) {
          throw FormatException('整合包不能覆盖启动器或版本文件：$relative');
        }
      }
      final overridesRoot = p.join(
        _cache(
          'pack-overrides:${session.project.source.name}:${session.release.id}',
        ),
        'files',
      );
      final icon = File(p.join(_cache('pack-icon:${task.id}'), 'pack-icon'));
      await extractPackOverrides(
        plan,
        overridesRoot,
        task.token,
        iconDestination: icon.path,
      );
      final projectIcon = session.project.icon;
      if (!await icon.exists() &&
          projectIcon != null &&
          projectIcon.isNotEmpty) {
        try {
          await catalog.network.download(
            DownloadFile(projectIcon, icon.path),
            task.token,
            onBytes: (bytes) {
              task.bytes += bytes;
              onChanged();
            },
            onCachedBytes: (bytes) {
              task.cachedBytes += bytes;
              onChanged();
            },
          );
          if (await icon.length() > 8 * 1024 * 1024) await icon.delete();
        } on Cancelled {
          rethrow;
        } catch (_) {
          // An unavailable thumbnail must not prevent installing the pack.
        }
      }
      File? languageOptions;
      if (session.settings.autoChinese) {
        languageOptions = File(
          p.join(_cache('pack-language:${task.id}'), 'options.txt'),
        );
        final override = plan.overrides.keys.where(isOptions).firstOrNull;
        final downloaded = session.files!
            .where((entry) => isOptions(p.relative(entry.$2, from: cacheRoot)))
            .firstOrNull;
        final source = File(
          override != null
              ? safeJoin(overridesRoot, override)
              : downloaded?.$2 ?? p.join(instance.gameDirectory, 'options.txt'),
        );
        final type = await FileSystemEntity.type(
          source.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.notFound) {
          throw const FormatException('游戏选项必须是普通文件。');
        }
        await languageOptions.parent.create(recursive: true);
        if (type == FileSystemEntityType.file) {
          await source.copy(languageOptions.path);
        } else {
          await languageOptions.writeAsBytes([]);
        }
        await setChineseGameOptions(
          languageOptions,
          plan.minecraft,
          task.token,
        );
      }
      final provenance = File(
        p.join(_cache('pack-provenance:${task.id}'), 'modpack.json'),
      );
      final authorFiles = <String, String>{
        for (final (_, cached) in session.files!)
          p.relative(cached, from: cacheRoot).replaceAll('\\', '/'): cached,
        for (final path in plan.overrides.keys)
          path.replaceAll('\\', '/'): safeJoin(overridesRoot, path),
        if (languageOptions != null) 'options.txt': languageOptions.path,
      };
      final fileHashes = await hashPackFiles(authorFiles);
      task.token.check();
      await writeJson(provenance, {
        'schemaVersion': 2,
        'source': session.project.source.name,
        'projectId': session.project.id,
        'releaseId': session.release.id,
        'name': plan.name,
        'version': plan.version,
        'published': session.release.published.toIso8601String(),
        'minecraft': plan.minecraft,
        'loader': plan.loader?.name,
        'loaderVersion': plan.loaderVersion,
        'optional': session.optional.toList(),
        'fileHashes': fileHashes,
        'managedFiles': [
          for (final (_, cached) in session.files!)
            p.relative(cached, from: cacheRoot),
          ...plan.overrides.keys,
        ],
      });
      final installedInstance = instance.copyWith(
        description: session.project.summary,
        category: '整合包',
        installation: {...instance.installation, 'modpack': true},
      );
      await publishFiles(
        instance.root,
        [
          for (final (_, cached) in session.files!)
            if (languageOptions == null ||
                !isOptions(p.relative(cached, from: cacheRoot)))
              (
                cached,
                safeJoin(
                  instance.gameDirectory,
                  p.relative(cached, from: cacheRoot),
                ),
              ),
          for (final path in plan.overrides.keys)
            if (languageOptions == null || !isOptions(path))
              (
                safeJoin(overridesRoot, path),
                safeJoin(instance.gameDirectory, path),
              ),
          if (languageOptions != null)
            (
              languageOptions.path,
              p.join(instance.gameDirectory, 'options.txt'),
            ),
          (provenance.path, p.join(instance.launcherDirectory, 'modpack.json')),
          if (await icon.exists())
            (icon.path, p.join(instance.launcherDirectory, 'pack-icon')),
        ],
        task.token,
        onProgress: (done, total) {
          task.done = done;
          task.total = total;
          onChanged();
        },
        finalize: session.registerInstance
            ? () => onInstalled(installedInstance)
            : () async {
                task.preparedInstance = installedInstance;
                try {
                  await onPreparedPackUpdate?.call(task);
                } catch (_) {
                  task.preparedInstance = null;
                  rethrow;
                }
              },
      );
      task.destination = instance.gameDirectory;
      task.state = ContentTaskState.completed;
      task.stage = session.registerInstance ? '安装完成' : '等待确认升级';
    } catch (_) {
      await _retainIncompleteBase(session, instance);
      rethrow;
    }
  }

  Future<void> _retainIncompleteBase(
    _PackSession session,
    GameInstance instance,
  ) async {
    final expected = safeJoin(
      p.join(session.settings.gameRoot, 'versions'),
      session.name,
    );
    if (!p.equals(instance.versionDirectory, expected)) return;
    try {
      final type = await FileSystemEntity.type(expected, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final retained = safeJoin(
          p.join(session.settings.gameRoot, '.fyl-trash'),
          'incomplete-pack-${DateTime.now().microsecondsSinceEpoch}-${session.name}',
        );
        await ensurePackParents(session.settings.gameRoot, retained);
        await Directory(expected).rename(retained);
      } else if (type != FileSystemEntityType.notFound) {
        return;
      }
      session.baseInstance = null;
    } catch (_) {
      // Keep ownership of the base so Retry can resume if retaining it failed.
    }
  }
}
