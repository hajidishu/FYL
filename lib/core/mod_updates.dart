import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'community_catalog.dart';
import 'community_models.dart';
import 'file_transaction.dart';
import 'local_mods.dart';
import 'models.dart';
import 'minecraft.dart' show writeJson;
import 'network.dart';
import 'pack_import.dart';

class ModFingerprint {
  final String path, hash;
  final int curse;
  const ModFingerprint(this.path, this.hash, this.curse);
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

bool _whitespace(int byte) =>
    byte == 9 || byte == 10 || byte == 13 || byte == 32;

/// SHA-1 and CurseForge's whitespace-filtered MurmurHash2, seed 1.
/// Both passes stream bounded chunks in a worker isolate.
Future<ModFingerprint> fingerprintMod(String path) => Isolate.run(() async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError('Mod 文件已变化，请刷新列表。');
  }
  final file = File(path);
  final before = await file.stat();
  if (before.size > 512 * 1024 * 1024) {
    throw const FormatException('Mod 文件超过 512 MB。');
  }
  final output = _DigestSink();
  final digest = sha1.startChunkedConversion(output);
  var length = 0;
  await for (final chunk in file.openRead()) {
    digest.add(chunk);
    for (final byte in chunk) {
      if (!_whitespace(byte)) length++;
    }
  }
  digest.close();
  const mask = 0xffffffff, multiplier = 0x5bd1e995;
  var hash = 1 ^ length, word = 0, count = 0;
  await for (final chunk in file.openRead()) {
    for (final byte in chunk) {
      if (_whitespace(byte)) continue;
      word |= byte << (count * 8);
      count++;
      if (count == 4) {
        var mixed = (word * multiplier) & mask;
        mixed ^= mixed >> 24;
        mixed = (mixed * multiplier) & mask;
        hash = ((hash * multiplier) & mask) ^ mixed;
        word = count = 0;
      }
    }
  }
  if (count > 0) hash = ((hash ^ word) * multiplier) & mask;
  hash ^= hash >> 13;
  hash = (hash * multiplier) & mask;
  hash ^= hash >> 15;
  final after = await file.stat();
  if (before.size != after.size || before.modified != after.modified) {
    throw StateError('Mod 文件在读取时发生了变化，请重新检查。');
  }
  return ModFingerprint(path, output.value.toString(), hash);
});

class IdentifiedMod {
  final LocalMod mod;
  final ModFingerprint fingerprint;
  final ContentVersion current;
  const IdentifiedMod(this.mod, this.fingerprint, this.current);
}

class ModUpdate {
  final IdentifiedMod installed;
  final ContentVersion latest;
  const ModUpdate(this.installed, this.latest);
}

class ModUpdateCheck {
  final Map<String, IdentifiedMod> identified;
  final Map<String, ModUpdate> updates;
  final List<String> notices;
  final int unidentified;
  const ModUpdateCheck({
    required this.identified,
    required this.updates,
    this.notices = const [],
    this.unidentified = 0,
  });
}

typedef ModUpdateProgress = void Function(String stage, int done, int total);

class ModUpdater {
  final CommunityCatalog catalog;
  final String supportDirectory;
  ModUpdater(this.catalog, this.supportDirectory);

  String _message(Object error) => error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceAll(
        catalog.settings.curseforgeApiKey.isEmpty
            ? '\u0000'
            : catalog.settings.curseforgeApiKey,
        '[已隐藏密钥]',
      );

  Future<ModUpdateCheck> check(
    GameInstance instance,
    List<LocalMod> mods,
    CancellationToken token, {
    ModUpdateProgress? onProgress,
  }) async {
    final loader = instanceModLoader(instance);
    if (loader == null) throw StateError('此版本未安装 Mod 加载器。');
    final notices = <String>{};
    final fingerprints = <String, ModFingerprint>{};
    for (var i = 0; i < mods.length; i++) {
      token.check();
      onProgress?.call('识别 Mod 文件', i, mods.length);
      try {
        final mod = mods[i];
        if (!p.equals(
          p.dirname(mod.path),
          p.join(instance.gameDirectory, 'mods'),
        )) {
          throw const FormatException('Mod 文件不属于此游戏版本。');
        }
        fingerprints[mod.path] = await fingerprintMod(mod.path);
      } on Cancelled {
        rethrow;
      } catch (e) {
        notices.add(_message(e));
      }
    }
    token.check();
    Json index = {};
    try {
      index =
          jsonDecode(
                await File(
                  p.join(
                    instance.gameDirectory,
                    'mods',
                    '.fyl-managed-mods.json',
                  ),
                ).readAsString(),
              )
              as Json;
    } catch (_) {}
    final preferredCurse = <String>{};
    for (final entry in index.entries) {
      if (!entry.key.startsWith('curseforge:') || entry.value is! Map) continue;
      final value = entry.value as Map;
      for (final fingerprint in fingerprints.values) {
        if (fingerprint.hash == value['sha1']) {
          preferredCurse.add(fingerprint.path);
        }
      }
    }
    final identified = <String, IdentifiedMod>{};
    final updates = <String, ModUpdate>{};
    for (var start = 0; start < mods.length; start += 100) {
      token.check();
      final batch = mods
          .skip(start)
          .take(100)
          .where((m) => fingerprints.containsKey(m.path))
          .toList();
      if (batch.isEmpty) continue;
      onProgress?.call('检查 Modrinth 更新', start, mods.length);
      try {
        final found = await catalog.versionsFromHashes([
          for (final m in batch) fingerprints[m.path]!.hash,
        ], token);
        for (final mod in batch) {
          final fingerprint = fingerprints[mod.path]!;
          final current = found[fingerprint.hash];
          if (current != null &&
              current.files.any((f) => f.hashes['sha1'] == fingerprint.hash)) {
            identified[mod.path] = IdentifiedMod(mod, fingerprint, current);
          }
        }
      } on Cancelled {
        rethrow;
      } catch (e) {
        notices.add('Modrinth：${_message(e)}');
      }
      if (catalog.settings.curseforgeApiKey.isNotEmpty) {
        final remaining = batch
            .where(
              (m) =>
                  !identified.containsKey(m.path) ||
                  preferredCurse.contains(m.path),
            )
            .toList();
        if (remaining.isNotEmpty) {
          onProgress?.call('检查 CurseForge 更新', start, mods.length);
          try {
            final found = await catalog.fingerprintMatches([
              for (final m in remaining) fingerprints[m.path]!.curse,
            ], token);
            for (final mod in remaining) {
              final fingerprint = fingerprints[mod.path]!;
              // Murmur2 identifies candidates; SHA-1 confirms the exact file.
              final current = found
                  .where(
                    (v) => v.files.any(
                      (f) => f.hashes['sha1'] == fingerprint.hash,
                    ),
                  )
                  .firstOrNull;
              if (current != null) {
                identified[mod.path] = IdentifiedMod(mod, fingerprint, current);
              }
            }
          } on Cancelled {
            rethrow;
          } catch (e) {
            notices.add('CurseForge：${_message(e)}');
          }
        }
      }
    }
    final mr = identified.values
        .where((m) => m.current.source == ContentSource.modrinth)
        .toList();
    for (final channel in ['release', 'beta', 'alpha']) {
      final group = mr.where((m) => m.current.releaseType == channel).toList();
      for (var start = 0; start < group.length; start += 100) {
        final batch = group.skip(start).take(100).toList();
        token.check();
        try {
          final found = await catalog.versionsFromHashes(
            [for (final m in batch) m.fingerprint.hash],
            token,
            minecraft: instance.version,
            loader: loader,
            channels: _channels(channel),
          );
          for (final mod in batch) {
            final latest = found[mod.fingerprint.hash];
            if (latest != null &&
                _channels(channel).contains(latest.releaseType) &&
                _newer(mod.current, latest, instance.version, loader)) {
              updates[mod.mod.path] = ModUpdate(mod, latest);
            }
          }
        } on Cancelled {
          rethrow;
        } catch (e) {
          notices.add('Modrinth：${_message(e)}');
        }
      }
    }
    final curse = identified.values
        .where((m) => m.current.source == ContentSource.curseforge)
        .toList();
    final versions = <String, Map<int, Future<ContentVersionPage>>>{};
    for (var i = 0; i < curse.length; i++) {
      token.check();
      final mod = curse[i];
      onProgress?.call('检查 CurseForge 更新', i, curse.length);
      try {
        final project = _project(mod.current, mod.mod.name);
        ContentVersion? latest;
        var pageNumber = 0;
        while (latest == null) {
          token.check();
          final page = await (versions[project.id] ??= {}).putIfAbsent(
            pageNumber,
            () => catalog.versions(
              project,
              token,
              minecraft: instance.version,
              loader: loader,
              page: pageNumber,
            ),
          );
          latest = page.versions
              .where(
                (v) =>
                    _channels(
                      mod.current.releaseType,
                    ).contains(v.releaseType) &&
                    _newer(mod.current, v, instance.version, loader),
              )
              .firstOrNull;
          if (latest != null || !page.hasMore) break;
          pageNumber++;
        }
        if (latest != null) updates[mod.mod.path] = ModUpdate(mod, latest);
      } on Cancelled {
        rethrow;
      } catch (e) {
        notices.add('CurseForge：${_message(e)}');
      }
    }
    if (catalog.settings.curseforgeApiKey.isEmpty &&
        identified.length < mods.length) {
      notices.add('未配置 CurseForge API Key，仅检查 Modrinth。');
    }
    onProgress?.call('检查完成', mods.length, mods.length);
    return ModUpdateCheck(
      identified: identified,
      updates: updates,
      notices: notices.toList(),
      unidentified: mods.length - identified.length,
    );
  }

  List<String> _channels(String channel) => switch (channel) {
    'alpha' => ['release', 'beta', 'alpha'],
    'beta' => ['release', 'beta'],
    _ => ['release'],
  };
  bool _newer(
    ContentVersion current,
    ContentVersion next,
    String minecraft,
    String loader,
  ) =>
      next.projectId == current.projectId &&
      next.id != current.id &&
      next.published.isAfter(current.published) &&
      next.supports(minecraft, loader) &&
      next.files.any((f) => f.name.toLowerCase().endsWith('.jar'));

  ContentProject _project(ContentVersion version, String name) =>
      ContentProject(
        source: version.source,
        kind: ContentKind.mod,
        id: version.projectId,
        slug: version.projectId,
        name: name,
        summary: '',
        author: '',
        website: '',
      );

  Future<void> apply(
    GameInstance instance,
    List<ModUpdate> updates,
    ModUpdateCheck check,
    CancellationToken token, {
    ModUpdateProgress? onProgress,
  }) async {
    if (updates.isEmpty) return;
    final loader = instanceModLoader(instance);
    final root = p.join(instance.gameDirectory, 'mods');
    if (await FileSystemEntity.type(
          instance.gameDirectory,
          followLinks: false,
        ) ==
        FileSystemEntityType.link) {
      throw const FormatException('游戏目录不能是符号链接。');
    }
    await ensurePackParents(
      instance.gameDirectory,
      p.join(root, 'placeholder'),
    );
    final planned = <String, ContentFile>{};
    String key(ContentSource source, String project) =>
        '${source.name}:$project';
    final explicit = {
      for (final update in updates)
        key(update.latest.source, update.latest.projectId): update.installed,
    };
    for (final update in updates) {
      token.check();
      if (!update.latest.supports(instance.version, loader)) {
        throw StateError('更新与当前游戏版本或加载器不兼容，请重新检查。');
      }
      onProgress?.call('解析更新依赖', planned.length, updates.length);
      final project = await catalog.project(
        update.latest.source,
        update.latest.projectId,
        ContentKind.mod,
        token,
      );
      final files = await catalog.modFiles(
        project,
        update.latest,
        instance,
        token,
      );
      for (final file in files) {
        final id = key(update.latest.source, file.projectId);
        final previous = planned[id];
        if (previous != null &&
            (previous.id != file.id ||
                previous.hashes['sha1'] != file.hashes['sha1'])) {
          throw StateError('所选更新的依赖版本冲突：${file.name}');
        }
        planned[id] = file;
      }
    }
    final allMods = await scanLocalMods(instance, token);
    final cache = p.join(supportDirectory, 'cache', 'mod-updates');
    final copies = <(String, String)>[];
    final removals = <String>{};
    final targets = <String>{};
    final replaced = <String, IdentifiedMod>{};
    Json index = {};
    final indexFile = File(p.join(root, '.fyl-managed-mods.json'));
    try {
      index = jsonDecode(await indexFile.readAsString()) as Json;
    } catch (_) {}
    var completed = 0;
    for (final entry in planned.entries) {
      token.check();
      final file = entry.value;
      var previous =
          explicit[entry.key] ??
          check.identified.values
              .where(
                (m) => key(m.current.source, m.current.projectId) == entry.key,
              )
              .firstOrNull;
      if (previous != null &&
          file.hashes['sha1'] == previous.fingerprint.hash) {
        await _unchanged(previous, root);
        continue;
      }
      if (previous != null &&
          !explicit.containsKey(entry.key) &&
          previous.current.id != file.id) {
        final known = check.updates[previous.mod.path]?.latest;
        final dependency = known?.id == file.id
            ? known!
            : await catalog.version(
                previous.current.source,
                file.projectId,
                file.id,
                token,
              );
        if (dependency.published.isBefore(previous.current.published)) {
          throw StateError('依赖 ${previous.mod.name} 需要回退版本，请先手动处理版本冲突。');
        }
      }
      if (file.urls.isEmpty) {
        throw StateError('${file.name} 不允许通过 API 下载，请从项目页面下载后从文件安装。');
      }
      final cached = p.join(
        cache,
        sha256
            .convert(utf8.encode('${entry.key}:${file.id}:${file.hashes}'))
            .toString(),
        contentFileName(file.name),
      );
      onProgress?.call('下载 ${file.name}', completed, planned.length);
      await catalog.network.download(file.download(cached), token);
      token.check();
      final metadata = await Isolate.run(() => readLocalMod(cached));
      if (metadata.warning != null) {
        throw FormatException('更新文件不是有效的 Mod：${file.name}');
      }
      if (previous == null && metadata.id.isNotEmpty) {
        final sameId = allMods.where((m) => m.id == metadata.id).toList();
        if (sameId.length > 1) {
          throw StateError('存在多个相同 ID 的 Mod，请先处理重复文件：${metadata.id}');
        }
        if (sameId.isNotEmpty) {
          previous = check.identified[sameId.single.path];
          if (previous == null) {
            throw StateError('依赖 ${metadata.name} 与本地未识别文件重复，请先手动处理。');
          }
        }
      }
      if (previous != null) {
        await _unchanged(previous, root);
        if (previous.mod.id.isNotEmpty &&
            metadata.id.isNotEmpty &&
            previous.mod.id != metadata.id) {
          throw StateError('更新文件的 Mod ID 与原文件不一致。');
        }
        if (replaced.containsKey(previous.mod.path)) {
          throw StateError('多个更新指向同一个 Mod 文件。');
        }
        replaced[previous.mod.path] = previous;
      }
      final target = safeJoin(
        root,
        '${contentFileName(file.name)}${previous?.mod.enabled == false ? '.disabled' : ''}',
      );
      if (!targets.add(p.normalize(target).toLowerCase())) {
        throw StateError('更新文件名称冲突：${file.name}');
      }
      if (await FileSystemEntity.type(target, followLinks: false) !=
              FileSystemEntityType.notFound &&
          (previous == null || !p.equals(target, previous.mod.path))) {
        throw StateError('目标文件已存在，请先刷新列表：${p.basename(target)}');
      }
      copies.add((cached, target));
      if (previous != null && !p.equals(previous.mod.path, target)) {
        removals.add(previous.mod.path);
      }
      index.removeWhere(
        (_, value) =>
            value is Map &&
            value['path'] ==
                (previous == null ? null : p.basename(previous.mod.path)),
      );
      index[entry.key] = {
        'path': p.basename(target),
        'version': file.id,
        'sha1': (await sha1.bind(File(cached).openRead()).first).toString(),
      };
      completed++;
    }
    for (final previous in replaced.values) {
      token.check();
      await _unchanged(previous, root);
    }
    final stagedIndex = File(
      p.join(cache, 'index-${DateTime.now().microsecondsSinceEpoch}.json'),
    );
    await writeJson(stagedIndex, index);
    try {
      onProgress?.call('应用 Mod 更新', 0, copies.length);
      await publishFiles(
        root,
        [...copies, (stagedIndex.path, indexFile.path)],
        token,
        removals: removals.toList(),
        onProgress: (done, total) => onProgress?.call('应用 Mod 更新', done, total),
      );
    } finally {
      if (await stagedIndex.exists()) await stagedIndex.delete();
    }
  }

  Future<void> _unchanged(IdentifiedMod previous, String root) async {
    final path = previous.mod.path;
    if (!p.equals(p.dirname(path), root) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        (await sha1.bind(File(path).openRead()).first).toString() !=
            previous.fingerprint.hash) {
      throw StateError('Mod 文件在检查后发生了变化，请刷新并重新检查更新。');
    }
  }
}
