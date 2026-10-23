import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'instance_tools.dart';
import 'minecraft.dart' show writeJson;
import 'models.dart';
import 'network.dart';
import 'pack_import.dart' show ensurePackParents;

Future<String> packFileHash(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

String _fileKey(String path) {
  final normalized = path.replaceAll('\\', '/');
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

Future<Json> readPackRecord(GameInstance instance) async {
  final file = File(p.join(instance.launcherDirectory, 'modpack.json'));
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException('此版本没有整合包来源记录。');
  }
  return jsonDecode(await file.readAsString()) as Json;
}

/// Hash author files before local settings are merged, so the next update can
/// distinguish author defaults from user modifications.
Future<Map<String, String>> hashPackFiles(Map<String, String> files) =>
    Isolate.run(
      () async => {
        for (final entry in files.entries)
          entry.key.replaceAll('\\', '/'): await packFileHash(entry.value),
      },
    );

bool _personal(String path) {
  final normalized = path.toLowerCase();
  return normalized.startsWith('saves/') ||
      normalized.startsWith('screenshots/') ||
      const {
        'options.txt',
        'optionsof.txt',
        'optionsshaders.txt',
        'servers.dat',
        'servers.dat_old',
        'usercache.json',
      }.contains(normalized);
}

class PackUpdatePreview {
  final GameInstance original, staged;
  final Map<String, String> before, incoming;
  final Set<String> preserve, remove, conflicts;
  final int added, replaced, deleted;
  final bool unknownBaseline;
  const PackUpdatePreview({
    required this.original,
    required this.staged,
    required this.before,
    required this.incoming,
    required this.preserve,
    required this.remove,
    required this.conflicts,
    required this.added,
    required this.replaced,
    required this.deleted,
    this.unknownBaseline = false,
  });
}

Future<Map<String, String>> _gameFiles(GameInstance instance) async {
  final files = <String, String>{};
  final root = instance.gameDirectory;
  await ensurePackParents(instance.root, p.join(root, '.scan'));
  await for (final entry in Directory(root).list(followLinks: false)) {
    final name = p.basename(entry.path);
    if (!isGameDataPath(name, instance)) continue;
    if (entry is Link) throw FormatException('游戏数据包含符号链接：$name');
    if (entry is File) {
      files[_fileKey(name)] = await packFileHash(entry.path);
    } else if (entry is Directory) {
      await for (final child in entry.list(
        recursive: true,
        followLinks: false,
      )) {
        if (child is Link) throw FormatException('游戏数据包含符号链接：${child.path}');
        if (child is File) {
          files[_fileKey(p.relative(child.path, from: root))] =
              await packFileHash(child.path);
        }
      }
    }
  }
  return files;
}

Future<PackUpdatePreview> previewPackUpdate(
  GameInstance original,
  GameInstance staged, {
  String? supportDirectory,
}) => Isolate.run(() async {
  final oldRecord = await readPackRecord(original);
  final nextRecord = await readPackRecord(staged);
  final baseline = <String, String>{
    for (final entry in Map<String, String>.from(
      oldRecord['fileHashes'] as Map? ?? {},
    ).entries)
      _fileKey(entry.key): entry.value,
  };
  final oldPaths = {
    ...baseline.keys,
    ...(oldRecord['managedFiles'] as List? ?? []).cast<String>().map(_fileKey),
  };
  // Pre-updater installations already retain their original downloaded files
  // and extracted overrides. Rebuild the baseline from those immutable author
  // copies instead of assuming the user's current mods are the originals.
  final cacheSource = oldRecord['originSource'] ?? oldRecord['source'];
  final cacheRelease = oldRecord['originReleaseId'] ?? oldRecord['releaseId'];
  if (supportDirectory != null &&
      cacheRelease is String &&
      const {'modrinth', 'curseforge'}.contains(cacheSource)) {
    final source = cacheSource, release = cacheRelease;
    String cached(String kind) => p.join(
      supportDirectory,
      'cache',
      'community',
      sha256.convert(utf8.encode('$kind:$source:$release')).toString(),
      'files',
    );
    for (final path in oldPaths.where((path) => !baseline.containsKey(path))) {
      for (final directory in [
        cached('pack-overrides'),
        cached('pack-files'),
      ]) {
        final file = safeJoin(directory, path);
        await ensurePackParents(supportDirectory, file);
        if (await FileSystemEntity.type(file, followLinks: false) ==
            FileSystemEntityType.file) {
          baseline[path] = await packFileHash(file);
          break;
        }
      }
    }
  }
  final incoming = <String, String>{
    for (final entry in Map<String, String>.from(
      nextRecord['fileHashes'] as Map,
    ).entries)
      _fileKey(entry.key): entry.value,
  };
  final current = await _gameFiles(original);
  final preserve = <String>{}, remove = <String>{}, conflicts = <String>{};
  var added = 0, replaced = 0, deleted = 0;
  for (final path in {...current.keys, ...oldPaths, ...incoming.keys}) {
    // Validate even paths from older metadata before they become filesystem IO.
    safeJoin(original.gameDirectory, path);
    safeJoin(staged.gameDirectory, path);
    if (!isGameDataPath(path, original) || !isGameDataPath(path, staged)) {
      throw FormatException('整合包文件路径无效：$path');
    }
    final local = current[path], next = incoming[path], old = baseline[path];
    if (local == next) continue;
    if (_personal(path)) {
      // Never install a bundled world over a user's world (including deletions).
      if (local != null) preserve.add(path);
      if (next != null) remove.add(path);
      continue;
    }
    if (!oldPaths.contains(path)) {
      if (local == null) {
        if (next != null) added++;
      } else if (next == null) {
        preserve.add(path);
      } else {
        conflicts.add(path);
      }
    } else if (old != null && local == old) {
      if (next == null) {
        deleted++;
      } else {
        replaced++;
      }
    } else if (old != null && next == old) {
      if (local != null) preserve.add(path);
      if (next != null) remove.add(path);
    } else {
      // Unknown legacy baseline, locally removed file, or both sides changed.
      conflicts.add(path);
    }
  }
  return PackUpdatePreview(
    original: original,
    staged: staged,
    before: current,
    incoming: incoming,
    preserve: preserve,
    remove: remove,
    conflicts: conflicts,
    added: added,
    replaced: replaced,
    deleted: deleted,
    unknownBaseline: oldPaths.any(
      (path) => !baseline.containsKey(path) && !_personal(path),
    ),
  );
});

/// Only the unregistered staging instance is edited. The current instance is
/// rechecked before publication; any changed file invalidates the preview.
Future<void> mergePackUpdate(
  PackUpdatePreview preview,
  Set<String> useIncoming,
  CancellationToken token,
) async {
  if (!preview.conflicts.containsAll(useIncoming)) {
    throw ArgumentError('升级冲突选项无效。');
  }
  final original = preview.original, staged = preview.staged;
  token.check();
  await Isolate.run(() async {
    final current = await _gameFiles(original);
    if (current.length != preview.before.length ||
        current.entries.any(
          (entry) => preview.before[entry.key] != entry.value,
        )) {
      throw StateError('游戏文件已变化，请重新预览升级。');
    }
    final keepLocal = preview.conflicts.difference(useIncoming);
    final removals = {...preview.remove, ...keepLocal};
    for (final path in removals) {
      final target = safeJoin(staged.gameDirectory, path);
      await ensurePackParents(staged.root, target);
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.file) {
        await File(target).delete();
      } else if (type != FileSystemEntityType.notFound) {
        throw FormatException('升级目标不是普通文件：$path');
      }
    }
    for (final path in {...preview.preserve, ...keepLocal}) {
      if (!preview.before.containsKey(path)) continue;
      final target = safeJoin(staged.gameDirectory, path);
      await ensurePackParents(staged.root, target);
      await File(target).parent.create(recursive: true);
      await File(safeJoin(original.gameDirectory, path)).copy(target);
    }
  });
  token.check();
}

Future<void> writePackUpdateJournal(String supportDirectory, Json value) =>
    writeJson(
      File(p.join(supportDirectory, 'pack-update-journal.json')),
      value,
    );

/// Interrupted directory swaps are recovered before a version can be launched.
Future<String?> recoverPackUpdate(
  String supportDirectory,
  List<GameInstance> instances,
) async {
  final journal = File(p.join(supportDirectory, 'pack-update-journal.json'));
  if (!await journal.exists()) return null;
  final data = jsonDecode(await journal.readAsString()) as Json;
  final old = GameInstance.fromJson(data['original'] as Json);
  final next = GameInstance.fromJson(data['updated'] as Json);
  final backup = data['backup'] as String;
  final allowed = p.join(old.root, '.fyl', 'pack-backups');
  if (!p.isWithin(
        p.normalize(p.absolute(allowed)),
        p.normalize(p.absolute(backup)),
      ) ||
      old.versionDirectory != next.versionDirectory) {
    throw const FormatException('整合包升级恢复记录无效。');
  }
  await ensurePackParents(old.root, backup);
  await ensurePackParents(old.root, old.versionDirectory);
  final committed = instances.any(
    (instance) =>
        instance.id == next.id &&
        instance.version == next.version &&
        jsonEncode(instance.installation) == jsonEncode(next.installation),
  );
  if (!committed && await Directory(backup).exists()) {
    if (await Directory(old.versionDirectory).exists()) {
      await Directory(old.versionDirectory).rename('$backup.interrupted');
    }
    await Directory(backup).rename(old.versionDirectory);
  }
  if (!await Directory(old.versionDirectory).exists()) {
    throw const FormatException('整合包版本目录与备份均无法读取。');
  }
  await journal.delete();
  return committed ? '整合包升级已完成，旧版本备份已保留。' : '已恢复中断升级前的整合包。';
}
