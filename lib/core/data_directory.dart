import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'minecraft.dart' show writeJson;
import 'models.dart';

String launcherInstallationDirectory({String? executable, String? os}) {
  final platform = os ?? Platform.operatingSystem;
  final path = executable ?? Platform.resolvedExecutable;
  final paths = p.Context(
    style: platform == 'windows' ? p.Style.windows : p.Style.posix,
  );
  var directory = paths.dirname(path);
  if (platform == 'macos' &&
      paths.basename(directory) == 'MacOS' &&
      paths.basename(paths.dirname(directory)) == 'Contents' &&
      paths
          .basename(paths.dirname(paths.dirname(directory)))
          .endsWith('.app')) {
    directory = paths.dirname(paths.dirname(paths.dirname(directory)));
  }
  return paths.normalize(directory);
}

String defaultDataDirectory() =>
    p.join(launcherInstallationDirectory(), 'FYL-data');

/// Resolve existing ancestors even when the final data folder does not exist.
Future<String> canonicalDataPath(String path) async {
  path = p.normalize(p.absolute(path));
  final tail = <String>[];
  while (!await Directory(path).exists()) {
    tail.insert(0, p.basename(path));
    final parent = p.dirname(path);
    if (parent == path) break;
    path = parent;
  }
  return p.normalize(
    p.joinAll([await Directory(path).resolveSymbolicLinks(), ...tail]),
  );
}

Future<void> ensureDataOutsideProgramComponents(
  String installation,
  String data,
  Iterable<String> components,
) async {
  final resolved = await canonicalDataPath(data);
  if (p.equals(resolved, await canonicalDataPath(installation))) {
    throw StateError('数据目录与程序组件重叠，请先移动数据目录。');
  }
  for (final name in components) {
    final reserved = await canonicalDataPath(p.join(installation, name));
    if (p.equals(resolved, reserved) || p.isWithin(reserved, resolved)) {
      throw StateError('数据目录与程序组件重叠，请先移动数据目录。');
    }
  }
}

/// Only reads the old location; path_provider's getter would create it again.
String? legacyDataDirectory() {
  final env = Platform.environment;
  if (Platform.isWindows && env['APPDATA'] != null) {
    return p.join(
      env['APPDATA']!,
      'dev.freeyourlauncher',
      'free_your_launcher',
    );
  }
  final home = env['HOME'];
  if (home == null) return null;
  if (Platform.isMacOS) {
    return p.join(
      home,
      'Library',
      'Application Support',
      'dev.freeyourlauncher.freeYourLauncher',
    );
  }
  if (Platform.isLinux) {
    return p.join(
      env['XDG_DATA_HOME'] ?? p.join(home, '.local', 'share'),
      'dev.freeyourlauncher.free_your_launcher',
    );
  }
  return null;
}

/// Rebase only known filesystem fields. Descriptions, URLs and JVM arguments
/// must never be changed by a global string replacement.
void rebaseDataPaths(Json data, String source, String destination) {
  String relocate(String path) =>
      p.isAbsolute(path) && (p.equals(path, source) || p.isWithin(source, path))
      ? p.join(destination, p.relative(path, from: source))
      : path;
  void fields(Map<dynamic, dynamic> object, List<String> names) {
    for (final name in names) {
      if (object[name] is String) {
        object[name] = relocate(object[name] as String);
      }
    }
  }

  final settings = data['settings'];
  if (settings is Map) {
    fields(settings, ['gameRoot', 'javaPath', 'backgroundPath']);
  }
  for (final instance in data['instances'] as List<dynamic>? ?? []) {
    if (instance is Map) {
      fields(instance, ['root', 'javaPath', 'managedJava', 'icon']);
    }
  }
  data['dataDirectory'] = destination;
}

class DataLocation {
  final String directory;
  final String? migrateFrom, migrationId;
  const DataLocation(this.directory, {this.migrateFrom, this.migrationId});
}

class DataMigrationProgress {
  final int files, totalFiles, bytes, totalBytes;
  const DataMigrationProgress(
    this.files,
    this.totalFiles,
    this.bytes,
    this.totalBytes,
  );
}

class DataDirectoryLease {
  final RandomAccessFile file;
  DataDirectoryLease._(this.file);
  static Future<DataDirectoryLease> acquire(String directory) async {
    await Directory(directory).create(recursive: true);
    final file = await File(
      p.join(directory, '.fyl-data.lock'),
    ).open(mode: FileMode.append);
    try {
      await file.lock(FileLock.exclusive);
      return DataDirectoryLease._(file);
    } catch (_) {
      await file.close();
      throw StateError('数据目录正被其他 FYL 进程使用，请关闭后重试。');
    }
  }

  Future<void> close() => file.close();
}

class DataDirectoryManager {
  final String installationDirectory;
  final String? directoryOverride;
  final String? startupDirectory;
  final String? Function() legacyDirectory;
  DataDirectoryManager({
    String? installationDirectory,
    this.directoryOverride,
    this.startupDirectory,
    this.legacyDirectory = legacyDataDirectory,
  }) : installationDirectory =
           installationDirectory ?? launcherInstallationDirectory();
  String get defaultDirectory => p.join(installationDirectory, 'FYL-data');
  File get configuration =>
      File(p.join(installationDirectory, 'fyl-storage.json'));

  Future<DataLocation> read() async {
    if (directoryOverride != null) {
      return DataLocation(_absolute(directoryOverride!));
    }
    for (final file in [configuration, File('${configuration.path}.bak')]) {
      if (!await file.exists()) continue;
      try {
        final json = jsonDecode(await file.readAsString()) as Json;
        final path = json['dataDirectory'];
        if (path is! String || path.trim().isEmpty) {
          throw const FormatException();
        }
        return DataLocation(
          _absolute(path),
          migrateFrom: json['migrateFrom'] as String?,
          migrationId: json['migrationId'] as String?,
        );
      } catch (_) {
        if (file.path.endsWith('.bak')) rethrow;
      }
    }
    if (await configuration.exists()) {
      throw const FormatException('数据目录配置无法读取，请检查 fyl-storage.json。');
    }
    // The updater carries the active profile across a restart without making it
    // a user-supplied override (which would disable changing it in Settings).
    if (startupDirectory?.trim().isNotEmpty == true &&
        await Directory(_absolute(startupDirectory!)).exists()) {
      return DataLocation(_absolute(startupDirectory!));
    }
    // A portable profile already beside the launcher remains authoritative.
    // Otherwise an existing pre-portable profile is opened in place, with no
    // first-run migration prompt and no writes to the installation directory.
    if (await _hasProfile(defaultDirectory)) {
      return DataLocation(defaultDirectory);
    }
    final legacy = legacyDirectory();
    if (legacy != null && await _hasProfile(_absolute(legacy))) {
      return DataLocation(_absolute(legacy));
    }
    return DataLocation(defaultDirectory);
  }

  Future<bool> _hasProfile(String directory) async {
    for (final name in ['launcher.json', 'launcher.json.bak']) {
      if (await FileSystemEntity.type(
            p.join(directory, name),
            followLinks: false,
          ) ==
          FileSystemEntityType.file) {
        return true;
      }
    }
    return false;
  }

  String _absolute(String path) => p.normalize(
    p.isAbsolute(path) ? path : p.join(installationDirectory, path),
  );

  Future<String> validateDestination(
    String target, {
    String? source,
    bool migrate = false,
  }) async {
    if (!p.isAbsolute(target.trim())) throw ArgumentError('数据目录需要使用绝对路径。');
    target = p.normalize(target.trim());
    if (p.equals(target, installationDirectory) ||
        p.dirname(target) == target) {
      throw ArgumentError('请选择单独的数据文件夹。');
    }
    final resolved = await canonicalDataPath(target);
    if (p.equals(resolved, await canonicalDataPath(installationDirectory)) ||
        p.dirname(resolved) == resolved) {
      throw ArgumentError('请选择单独的数据文件夹。');
    }
    for (final name in ['data', 'lib', 'plugins']) {
      final reserved = await canonicalDataPath(
        p.join(installationDirectory, name),
      );
      if (p.equals(resolved, reserved) || p.isWithin(reserved, resolved)) {
        throw ArgumentError('数据目录不能放在程序资源目录 $name 内。');
      }
    }
    if (source != null) {
      final original = await canonicalDataPath(source);
      if (p.equals(original, resolved) ||
          p.isWithin(original, resolved) ||
          p.isWithin(resolved, original)) {
        throw ArgumentError('新旧数据目录不能相同，也不能互相包含。');
      }
    }
    final type = await FileSystemEntity.type(target, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw ArgumentError('数据目录必须是普通文件夹，不能是文件或链接。');
    }
    if (migrate &&
        type == FileSystemEntityType.directory &&
        !await Directory(target).list().isEmpty) {
      throw StateError('目标文件夹不是空的，请选择空文件夹，或取消自动迁移以使用目标中的数据。');
    }
    if (!migrate &&
        type == FileSystemEntityType.directory &&
        !await Directory(target).list().isEmpty &&
        !await File(p.join(target, 'launcher.json')).exists() &&
        !await File(p.join(target, 'launcher.json.bak')).exists() &&
        !await File(p.join(target, '.fyl-data.lock')).exists()) {
      throw StateError('此文件夹包含其他文件，请选择空文件夹或已有的 FYL 数据目录。');
    }
    return target;
  }

  Future<void> select(
    String target, {
    String? source,
    bool migrate = false,
  }) async {
    if (directoryOverride != null) {
      throw StateError('当前数据目录由启动参数指定，请修改 --data-dir 或 FYL_DATA_DIR。');
    }
    target = await validateDestination(
      target,
      source: source,
      migrate: migrate,
    );
    await _write(
      DataLocation(
        target,
        migrateFrom: migrate ? source : null,
        migrationId: migrate
            ? DateTime.now().microsecondsSinceEpoch.toString()
            : null,
      ),
    );
  }

  Future<void> _write(DataLocation location) => writeJson(configuration, {
    'schemaVersion': 1,
    'dataDirectory': p.isWithin(installationDirectory, location.directory)
        ? p.relative(location.directory, from: installationDirectory)
        : location.directory,
    if (location.migrateFrom != null) 'migrateFrom': location.migrateFrom,
    if (location.migrationId != null) 'migrationId': location.migrationId,
  });

  Future<void> restore(String directory) async {
    await _write(DataLocation(directory));
    await configuration.copy('${configuration.path}.bak');
  }

  Future<String> activate({
    void Function(DataMigrationProgress)? onProgress,
  }) async {
    final location = await read();
    await validateDestination(location.directory);
    if (location.migrateFrom != null) {
      final id = location.migrationId;
      if (id == null || !RegExp(r'^\d{10,20}$').hasMatch(id)) {
        throw const FormatException('迁移记录无效。');
      }
      final port = ReceivePort();
      final subscription = port.listen((event) {
        if (event is DataMigrationProgress) onProgress?.call(event);
      });
      final sender = port.sendPort;
      try {
        await _runDataCopy(
          location.migrateFrom!,
          location.directory,
          id,
          sender,
        );
      } finally {
        await subscription.cancel();
        port.close();
      }
    }
    await Directory(location.directory).create(recursive: true);
    final probe = File(
      p.join(
        location.directory,
        '.write-test-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probe.writeAsBytes([], flush: true);
    } finally {
      if (await probe.exists()) await probe.delete();
    }
    return location.directory;
  }

  /// Called after the new controller has loaded successfully. Copies and their
  /// source are kept until this point; an interrupted startup can safely retry.
  Future<String?> completeMigration() async {
    if (directoryOverride != null) return null;
    final location = await read();
    if (location.migrateFrom == null) return null;
    await _write(DataLocation(location.directory));
    await configuration.copy('${configuration.path}.bak');
    try {
      await _runDataCleanup(
        location.migrateFrom!,
        location.directory,
        location.migrationId!,
      );
      return null;
    } catch (_) {
      return '数据已迁移；旧目录有文件被占用或发生变化，未清理：${location.migrateFrom}';
    }
  }
}

// Keep isolate closures in their own scope; a UI progress callback must never
// become part of the object graph sent to the worker.
Future<void> _runDataCopy(
  String source,
  String target,
  String id,
  SendPort events,
) => Isolate.run(() => _copyDataDirectory(source, target, id, events));
Future<void> _runDataCleanup(String source, String target, String id) =>
    Isolate.run(() => _cleanMigratedSource(source, target, id));

Future<Json> _readConfiguration(String directory) async {
  for (final name in ['launcher.json', 'launcher.json.bak']) {
    try {
      return jsonDecode(await File(p.join(directory, name)).readAsString())
          as Json;
    } catch (_) {
      /* Try backup. */
    }
  }
  throw StateError('源目录没有可读取的 FYL 配置，原数据已保留。');
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _copyDataDirectory(
  String source,
  String destination,
  String id,
  SendPort events,
) async {
  final marker = File(p.join(destination, '.fyl-migration.json'));
  if (await marker.exists()) {
    final json = jsonDecode(await marker.readAsString()) as Json;
    if (json['id'] == id &&
        json['source'] == source &&
        json['complete'] == true) {
      await _verifyDestination(destination, json);
      return;
    }
    throw StateError('目标目录包含其他迁移记录，原数据已保留。');
  }
  final manager = DataDirectoryManager(
    installationDirectory: p.dirname(destination),
  );
  await manager.validateDestination(destination, source: source, migrate: true);
  if (await FileSystemEntity.type(source, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('源数据目录不存在或不是普通文件夹。');
  }
  final sourceLease = await DataDirectoryLease.acquire(source);
  final staging = Directory('$destination.fyl-migration-$id');
  final owner = File(p.join(staging.path, '.fyl-migration-owner'));
  try {
    await _readConfiguration(source);
    if (await staging.exists()) {
      // Only remove the uniquely named staging directory owned by this pending migration.
      if (!await owner.exists() ||
          await owner.readAsString() != '$source\n$destination\n$id') {
        throw StateError('迁移临时目录已被占用，请选择其他目标。');
      }
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    await File(
      p.join(staging.path, '.fyl-migration-owner'),
    ).writeAsString('$source\n$destination\n$id', flush: true);
    final entries = await Directory(
      source,
    ).list(recursive: true, followLinks: false).toList();
    final files = entries
        .whereType<File>()
        .where((file) => p.basename(file.path) != '.fyl-data.lock')
        .toList();
    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await file.length();
    }
    var bytes = 0, done = 0;
    final fingerprints = <String, String>{};
    final links = <String, String>{};
    final directories = <String>[];
    final clock = Stopwatch()..start();
    events.send(DataMigrationProgress(0, files.length, 0, totalBytes));
    for (final entry in entries) {
      final relative = p.relative(entry.path, from: source);
      final path = p.join(staging.path, relative);
      if (entry is Directory) {
        await Directory(path).create(recursive: true);
        directories.add(relative);
      } else if (entry is File && p.basename(entry.path) != '.fyl-data.lock') {
        final copy = File(path);
        await copy.parent.create(recursive: true);
        await entry.copy(copy.path);
        final digest = await _digest(copy);
        if (digest != await _digest(entry)) {
          throw StateError('文件在迁移时发生变化：$relative。原数据已保留。');
        }
        fingerprints[relative] = digest;
        bytes += await copy.length();
        done++;
        if (clock.elapsedMilliseconds >= 100 || done == files.length) {
          events.send(
            DataMigrationProgress(done, files.length, bytes, totalBytes),
          );
          clock.reset();
        }
      } else if (entry is Link) {
        final target = await entry.target();
        links[relative] = target;
        final resolved = p.normalize(p.join(p.dirname(entry.path), target));
        if (!p.isWithin(source, resolved)) {
          throw StateError('数据目录含有指向外部的链接：$relative。请先移出该链接。');
        }
        await Directory(p.dirname(path)).create(recursive: true);
        final rebased = p.join(destination, p.relative(resolved, from: source));
        await Link(path).create(p.isAbsolute(target) ? rebased : target);
      }
    }
    final configuration = await _readConfiguration(staging.path);
    rebaseDataPaths(configuration, source, destination);
    // Do not leave a backup pointing back into the old directory.
    final text = const JsonEncoder.withIndent('  ').convert(configuration);
    await File(
      p.join(staging.path, 'launcher.json'),
    ).writeAsString(text, flush: true);
    await File(
      p.join(staging.path, 'launcher.json.bak'),
    ).writeAsString(text, flush: true);
    await File(p.join(staging.path, '.fyl-migration.json')).writeAsString(
      jsonEncode({
        'id': id,
        'source': source,
        'complete': true,
        'files': fingerprints,
        'links': links,
        'directories': directories,
      }),
      flush: true,
    );
    if (await Directory(destination).exists()) {
      if (!await Directory(destination).list().isEmpty) {
        throw StateError('目标目录已被其他程序修改，原数据已保留。');
      }
      await Directory(destination).delete();
    }
    await staging.rename(destination);
    await File(p.join(destination, '.fyl-migration-owner')).delete();
  } catch (_) {
    try {
      if (await FileSystemEntity.type(staging.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          await owner.exists() &&
          await owner.readAsString() == '$source\n$destination\n$id') {
        await staging.delete(recursive: true);
      }
    } catch (_) {
      /* Preserve the original migration error. */
    }
    rethrow;
  } finally {
    await sourceLease.close();
  }
}

Future<void> _cleanMigratedSource(
  String source,
  String destination,
  String id,
) async {
  if (p.equals(source, destination) ||
      p.isWithin(source, destination) ||
      p.isWithin(destination, source)) {
    throw StateError('数据目录重叠，不能清理。');
  }
  final marker = File(p.join(destination, '.fyl-migration.json'));
  final json = jsonDecode(await marker.readAsString()) as Json;
  if (json['id'] != id ||
      json['source'] != source ||
      json['complete'] != true) {
    throw StateError('迁移记录不匹配。');
  }
  final hashes = (json['files'] as Map).cast<String, String>();
  final links = (json['links'] as Map? ?? {}).cast<String, String>();
  final directories = (json['directories'] as List<dynamic>? ?? [])
      .cast<String>()
      .toSet();
  await _verifyDestination(destination, json);
  final lease = await DataDirectoryLease.acquire(source);
  try {
    final actual = <String>{};
    final actualLinks = <String>{}, actualDirectories = <String>{};
    await for (final entry in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      final name = p.relative(entry.path, from: source);
      if (entry is Link) {
        if (links[name] != await entry.target()) throw StateError('源链接已变化。');
        actualLinks.add(name);
        continue;
      }
      if (entry is Directory) {
        if (!directories.contains(name)) throw StateError('源目录已变化。');
        actualDirectories.add(name);
        continue;
      }
      if (entry is! File || p.basename(entry.path) == '.fyl-data.lock') {
        continue;
      }
      if (hashes[name] != await _digest(entry)) throw StateError('源文件已变化。');
      actual.add(name);
    }
    if (actual.length != hashes.length ||
        actualLinks.length != links.length ||
        actualDirectories.length != directories.length) {
      throw StateError('源目录已变化。');
    }
  } finally {
    await lease.close();
  }
  // The source was explicitly selected for migration and every source file was
  // verified above. Directory deletion does not follow child symbolic links.
  await Directory(source).delete(recursive: true);
  await marker.delete();
}

Future<void> _verifyDestination(String directory, Json marker) async {
  final files = (marker['files'] as Map).cast<String, String>();
  for (final entry in files.entries) {
    // Configuration is rebased and may be upgraded by initialize().
    if (entry.key == 'launcher.json' || entry.key == 'launcher.json.bak') {
      continue;
    }
    final file = File(safeJoin(directory, entry.key));
    if (!await file.exists() || await _digest(file) != entry.value) {
      throw StateError('迁移后的文件未通过校验：${entry.key}。原数据已保留。');
    }
  }
  await _readConfiguration(directory);
}
