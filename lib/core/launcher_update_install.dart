import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'data_directory.dart';
import 'build_info.dart';
import 'minecraft.dart' show writeJson;
import 'models.dart';
import 'pack_import.dart' show ensurePackParents;
import 'pack_updates.dart' show packFileHash;

const _manifestName = 'fyl-package.json';
const _journalName = '.fyl-update-journal.json';
bool _startupConfirmed = false;

Future<Json?> readLauncherUpdateJournal(File file) async {
  var found = false;
  for (final candidate in [file, File('${file.path}.bak')]) {
    if (!await candidate.exists()) continue;
    found = true;
    try {
      return jsonDecode(await candidate.readAsString()) as Json;
    } catch (_) {
      /* The previous durable journal may still be readable. */
    }
  }
  if (found) throw const FormatException('启动器恢复记录无效。');
  return null;
}

Future<void> _clearCompletedJournal(File file) async {
  // Never leave an applying-phase backup after deleting a committed journal.
  try {
    final backup = File('${file.path}.bak');
    if (await backup.exists()) await backup.delete();
    if (await file.exists()) await file.delete();
  } catch (_) {
    /* Keep the complete primary record for the next startup. */
  }
}

Future<void> completeLauncherUpdateJournal(File file, Json journal) async {
  await writeJson(file, {...journal, 'phase': 'complete'});
  await _clearCompletedJournal(file);
}

String _relative(String value) {
  final normalized = value.replaceAll('\\', '/');
  if (normalized.isEmpty ||
      p.posix.isAbsolute(normalized) ||
      normalized.split('/').any((part) => part == '..' || part.contains(':')) ||
      p.posix.normalize(normalized) == '.') {
    throw const FormatException('启动器更新包路径无效。');
  }
  return p.posix.normalize(normalized);
}

bool _component(String name, String os) {
  if (const {
    _manifestName,
    'LICENSE-FYL.txt',
    'ARTWORK-SOURCES.txt',
    'SOURCE.txt',
  }.contains(name)) {
    return true;
  }
  if (os == 'windows') {
    return name == 'data' ||
        name == 'free_your_launcher.exe' ||
        RegExp(r'^[A-Za-z0-9_.-]+\.dll$').hasMatch(name);
  }
  if (os == 'linux') {
    return const {'data', 'lib', 'free_your_launcher'}.contains(name);
  }
  return name == 'free_your_launcher.app';
}

Future<Json> verifyLauncherBundle(
  String root,
  String version,
  String os,
) async {
  final file = File(p.join(root, _manifestName));
  await ensurePackParents(root, file.path);
  if (await file.length() > 8 * 1024 * 1024) {
    throw const FormatException('启动器安装清单过大。');
  }
  final manifest = jsonDecode(await file.readAsString()) as Json;
  final target = os == 'osx' || os == 'macos' ? 'macos' : os;
  if (manifest['schemaVersion'] != 1 ||
      manifest['version'] != version ||
      manifest['target'] != target) {
    throw const FormatException('启动器更新包与目标版本或系统不匹配。');
  }
  final files = Map<String, dynamic>.from(manifest['files'] as Map);
  final links = Map<String, dynamic>.from(manifest['links'] as Map? ?? {});
  if (files.length + links.length > 20000) {
    throw const FormatException('启动器更新包文件数量过多。');
  }
  for (final entry in files.entries) {
    final relative = _relative(entry.key);
    if (!_component(relative.split('/').first, target)) {
      throw const FormatException('更新包包含非程序文件。');
    }
    final path = safeJoin(root, relative);
    await ensurePackParents(root, path);
    final info = entry.value as Json;
    if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file ||
        await File(path).length() != info['size'] ||
        await packFileHash(path) != info['sha256']) {
      throw FormatException('启动器文件校验失败：$relative');
    }
  }
  for (final entry in links.entries) {
    if (target != 'macos') throw const FormatException('更新包包含不支持的符号链接。');
    final relative = _relative(entry.key);
    if (!_component(relative.split('/').first, target)) {
      throw const FormatException('更新包包含非程序文件。');
    }
    final path = safeJoin(root, relative);
    final expected = entry.value as String;
    final resolved = p.normalize(p.join(p.dirname(path), expected));
    if (p.isAbsolute(expected) ||
        !p.isWithin(root, resolved) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.link ||
        await Link(path).target() != expected ||
        !p.isWithin(root, await Link(path).resolveSymbolicLinks())) {
      throw const FormatException('启动器更新包链接无效。');
    }
  }
  final entrypoint = _relative(manifest['entrypoint'] as String);
  if (!files.containsKey(entrypoint)) throw const FormatException('更新包缺少启动程序。');
  return manifest;
}

Future<String> prepareLauncherBundle(
  String archivePath,
  String workspace,
  String version,
  String os,
) => Isolate.run(() async {
  final unpacked = p.join(workspace, 'unpacked');
  await Directory(unpacked).create();
  final input = InputFileStream(archivePath);
  InputFileStream? tarInput;
  try {
    late Archive archive;
    if (os == 'linux') {
      final tar = OutputFileStream(p.join(workspace, 'bundle.tar'));
      bool decoded;
      try {
        decoded = GZipDecoder().decodeStream(
          input,
          tar,
          verify: true,
          maxOutputSize: 512 * 1024 * 1024,
        );
      } finally {
        tar.close();
      }
      if (!decoded) throw const FormatException('启动器更新包解压失败。');
      tarInput = InputFileStream(p.join(workspace, 'bundle.tar'));
      final decoder = TarDecoder();
      archive = decoder.decodeStream(tarInput, verify: true);
      if (decoder.files.any(
        (entry) => !const {'0', '\u0000', '5'}.contains(entry.typeFlag),
      )) {
        throw const FormatException('启动器更新包包含不支持的文件类型。');
      }
    } else {
      archive = ZipDecoder().decodeStream(input, verify: true);
    }
    var size = 0;
    final paths = <String>{};
    if (archive.files.length > 20000) {
      throw const FormatException('启动器更新包文件数量过多。');
    }
    for (final entry in archive.files) {
      final name = _relative(entry.name.replaceAll(RegExp(r'[/\\]+$'), ''));
      if (!(name == 'FYL' ||
          name.startsWith('FYL/') ||
          os == 'osx' &&
              (name == '__MACOSX' || name.startsWith('__MACOSX/')))) {
        throw const FormatException('启动器更新包目录结构无效。');
      }
      if (!paths.add(name.toLowerCase())) {
        throw const FormatException('启动器更新包包含重复路径。');
      }
      size += entry.size;
      if (size > 512 * 1024 * 1024) {
        throw const FormatException('启动器更新包解压大小超过限制。');
      }
      if (entry.isSymbolicLink) {
        final link = entry.symbolicLink!;
        final resolved = p.posix.normalize(
          p.posix.join(p.posix.dirname(name), link),
        );
        if (os != 'osx' ||
            p.posix.isAbsolute(link) ||
            !resolved.startsWith('FYL/')) {
          throw const FormatException('启动器更新包链接无效。');
        }
      }
    }
    // macOS ditto preserves framework links and resource attributes. Other
    // platforms use the archive's bounded stream extraction in this worker.
    if (os == 'osx') {
      final result = await Process.run('/usr/bin/ditto', [
        '-x',
        '-k',
        archivePath,
        unpacked,
      ]);
      if (result.exitCode != 0) throw StateError('启动器更新包解压失败：${result.stderr}');
    } else {
      await extractArchiveToDisk(archive, unpacked, maxSize: 512 * 1024 * 1024);
      if (os == 'linux') {
        // The archive library deliberately extracts without executable bits.
        final modes = <int, List<String>>{};
        for (final entry in archive.files.where((entry) => entry.isFile)) {
          modes
              .putIfAbsent(entry.mode & 0x1ff, () => [])
              .add(safeJoin(unpacked, _relative(entry.name)));
        }
        for (final mode in modes.entries) {
          for (var offset = 0; offset < mode.value.length; offset += 128) {
            final result = await Process.run('/bin/chmod', [
              mode.key.toRadixString(8),
              ...mode.value.skip(offset).take(128),
            ]);
            if (result.exitCode != 0) {
              throw StateError('无法保留程序文件权限。');
            }
          }
        }
      }
    }
  } finally {
    tarInput?.close();
    input.close();
  }
  final root = p.join(unpacked, 'FYL');
  await verifyLauncherBundle(root, version, os);
  return root;
});

Future<void> _copyComponent(String source, String destination) async {
  final type = await FileSystemEntity.type(source, followLinks: false);
  if (type == FileSystemEntityType.link) {
    await Link(destination).create(await Link(source).target());
  } else if (type == FileSystemEntityType.file) {
    await File(source).copy(destination);
    if (!Platform.isWindows) {
      final mode = (await File(source).stat()).mode & 0x1ff;
      final result = await Process.run('/bin/chmod', [
        mode.toRadixString(8),
        destination,
      ]);
      if (result.exitCode != 0) throw StateError('无法保留程序文件权限。');
    }
  } else if (type == FileSystemEntityType.directory) {
    if (Platform.isMacOS) {
      final result = await Process.run('/usr/bin/ditto', [source, destination]);
      if (result.exitCode != 0) throw StateError('无法复制程序组件：${result.stderr}');
      return;
    }
    await Directory(destination).create();
    await for (final entry in Directory(source).list(followLinks: false)) {
      await _copyComponent(
        entry.path,
        p.join(destination, p.basename(entry.path)),
      );
    }
  } else {
    throw const FormatException('程序组件不存在。');
  }
}

Future<void> _move(String source, String destination) async {
  final type = await FileSystemEntity.type(source, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    await Directory(source).rename(destination);
  } else if (type == FileSystemEntityType.file) {
    await File(source).rename(destination);
  } else {
    throw const FormatException('程序组件不是普通文件或目录。');
  }
}

Future<bool> _alive(int processId) async {
  if (processId <= 0) return false;
  if (Platform.isWindows) {
    final result = await Process.run('tasklist.exe', [
      '/FI',
      'PID eq $processId',
      '/FO',
      'CSV',
      '/NH',
    ]);
    if (result.exitCode != 0) throw StateError('无法确认启动器进程状态。');
    return result.stdout.toString().contains('"$processId"');
  }
  return (await Process.run('/bin/kill', ['-0', '$processId'])).exitCode == 0;
}

Future<void> _waitForExit(int processId, {File? cancelled}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
  while (await _alive(processId)) {
    if (cancelled != null && await cancelled.exists()) return;
    if (DateTime.now().isAfter(deadline)) throw StateError('启动器未退出，更新已停止。');
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

Future<Json> _readPlan(String path) async {
  final file = File(path);
  if (await file.length() > 65536) throw const FormatException('启动器更新计划无效。');
  final plan = jsonDecode(await file.readAsString()) as Json;
  final data = p.normalize(p.absolute(plan['dataDirectory'] as String));
  final workspace = p.dirname(p.normalize(p.absolute(path)));
  final installation = p.normalize(p.absolute(plan['installation'] as String));
  if (plan['schemaVersion'] != 1 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(plan['nonce'] as String) ||
      !p.isWithin(p.join(data, 'cache', 'launcher-updates'), workspace) ||
      p.normalize(plan['payload'] as String) !=
          p.join(workspace, 'unpacked', 'FYL') ||
      p.dirname(installation) == installation ||
      p.equals(installation, data)) {
    throw const FormatException('启动器更新计划路径无效。');
  }
  await ensurePackParents(data, path);
  await ensurePackParents(installation, p.join(installation, _journalName));
  await ensureDataOutsideProgramComponents(installation, data, const [
    'data',
    'lib',
    'plugins',
    'free_your_launcher.app',
  ]);
  return plan;
}

Set<String> _roots(Json manifest, String os) {
  final paths = {
    ...(manifest['files'] as Map).keys.cast<String>(),
    ...(manifest['links'] as Map? ?? {}).keys.cast<String>(),
    _manifestName,
  };
  final roots = paths.map((path) => _relative(path).split('/').first).toSet();
  if (roots.any((name) => !_component(name, os))) {
    throw const FormatException('更新包包含非程序组件。');
  }
  return roots;
}

Future<void> _rollback(Json journal, Json plan) async {
  final installation = plan['installation'] as String;
  final nonce = plan['nonce'] as String;
  final backup = safeJoin(installation, '.fyl-update-backup-$nonce');
  final retained = safeJoin(installation, '.fyl-update-failed-$nonce');
  await ensurePackParents(installation, p.join(backup, '.check'));
  await ensurePackParents(installation, p.join(retained, '.check'));
  await Directory(retained).create(recursive: true);
  for (final change in (journal['changes'] as List).cast<Json>().reversed) {
    final name = change['name'] as String;
    final os = Platform.isMacOS ? 'macos' : Platform.operatingSystem;
    if (!_component(name, os) || name.contains('/') || name.contains('\\')) {
      throw const FormatException('启动器恢复记录无效。');
    }
    final target = safeJoin(installation, name),
        previous = safeJoin(backup, name);
    final backedUp =
        await FileSystemEntity.type(previous, followLinks: false) !=
        FileSystemEntityType.notFound;
    if (backedUp || change['existed'] == false) {
      if (await FileSystemEntity.type(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await _move(target, safeJoin(retained, name));
      }
      if (backedUp) await _move(previous, target);
    }
  }
  final configuration = File(
    p.join(
      p.dirname(journal['plan'] as String),
      'configuration-before-update.json',
    ),
  );
  if (await configuration.exists()) {
    await configuration.copy(
      p.join(plan['dataDirectory'] as String, 'launcher.json'),
    );
  }
}

Future<int> _restart(Json plan, Json manifest, {String? readyPlan}) async {
  final installation = plan['installation'] as String;
  final override = plan['directoryOverride'] as String?;
  final process = await Process.start(
    safeJoin(installation, manifest['entrypoint'] as String),
    override == null ? [] : ['--data-dir', override],
    workingDirectory: installation,
    mode: ProcessStartMode.detached,
    environment: {
      'FYL_APPLY_UPDATE': '',
      'FYL_RECOVER_UPDATE': '',
      'FYL_UPDATE_READY_PLAN': readyPlan ?? '',
      'FYL_DATA_DIR': override ?? '',
      'FYL_RESTART_DATA_DIR': plan['dataDirectory'] as String,
    },
  );
  return process.pid;
}

Future<void> _apply(String planPath, {int? recoveryParent}) async {
  final plan = await _readPlan(planPath);
  final installation = plan['installation'] as String,
      nonce = plan['nonce'] as String;
  final workspace = p.dirname(planPath);
  final journalFile = File(p.join(installation, _journalName));
  final resultFile = File(
    p.join(plan['dataDirectory'] as String, 'launcher-update-result.json'),
  );
  final os = Platform.isMacOS ? 'macos' : Platform.operatingSystem;
  RandomAccessFile? lock;
  var locked = false;
  Json? journal, oldManifest;
  int? childPid;
  var acknowledged = false;
  try {
    final cancelled = File(p.join(workspace, 'cancelled-$nonce'));
    await writeJson(File(p.join(workspace, 'helper-ready-$nonce.json')), {
      'nonce': nonce,
      'pid': pid,
    });
    await _waitForExit(
      recoveryParent ?? plan['parentPid'] as int,
      cancelled: cancelled,
    );
    if (await cancelled.exists()) return;
    lock = await File(
      p.join(installation, '.fyl-update-lock'),
    ).open(mode: FileMode.append);
    await lock.lock(FileLock.exclusive);
    locked = true;
    if (recoveryParent != null) {
      journal = (await readLauncherUpdateJournal(journalFile))!;
      if (journal['plan'] != planPath) {
        throw const FormatException('启动器恢复记录无效。');
      }
      if (journal['childPid'] is int) {
        await _waitForExit(journal['childPid'] as int);
      }
      await _rollback(journal, plan);
      await completeLauncherUpdateJournal(journalFile, journal);
      oldManifest =
          jsonDecode(
                await File(p.join(installation, _manifestName)).readAsString(),
              )
              as Json;
      await writeJson(resultFile, {'error': '已恢复中断更新前的启动器。'});
      await _restart(plan, oldManifest);
      return;
    }
    final incoming = await verifyLauncherBundle(
      plan['payload'] as String,
      plan['version'] as String,
      os,
    );
    oldManifest =
        jsonDecode(
              await File(p.join(installation, _manifestName)).readAsString(),
            )
            as Json;
    final newRoots = _roots(incoming, os),
        allRoots = {..._roots(oldManifest, os), ..._roots(incoming, os)};
    final staging = safeJoin(installation, '.fyl-update-stage-$nonce');
    final backup = safeJoin(installation, '.fyl-update-backup-$nonce');
    await ensureDataOutsideProgramComponents(
      installation,
      plan['dataDirectory'] as String,
      allRoots,
    );
    await Directory(staging).create();
    await Directory(backup).create();
    for (final name in allRoots) {
      if (newRoots.contains(name)) {
        await _copyComponent(
          safeJoin(plan['payload'] as String, name),
          safeJoin(staging, name),
        );
      }
    }
    final config = File(
      p.join(plan['dataDirectory'] as String, 'launcher.json'),
    );
    if (await config.exists()) {
      await config.copy(p.join(workspace, 'configuration-before-update.json'));
    }
    journal = {
      'plan': planPath,
      'phase': 'applying',
      'changes': [
        for (final name in allRoots)
          {
            'name': name,
            'existed':
                await FileSystemEntity.type(
                  safeJoin(installation, name),
                  followLinks: false,
                ) !=
                FileSystemEntityType.notFound,
          },
      ],
    };
    await writeJson(journalFile, journal);
    for (final change in (journal['changes'] as List).cast<Json>()) {
      final name = change['name'] as String,
          target = safeJoin(installation, change['name'] as String);
      if (change['existed'] == true) {
        await _move(target, safeJoin(backup, name));
      }
      if (newRoots.contains(name)) await _move(safeJoin(staging, name), target);
    }
    childPid = await _restart(plan, incoming, readyPlan: planPath);
    journal['childPid'] = childPid;
    await writeJson(journalFile, journal);
    final ready = File(p.join(workspace, 'ready-$nonce.json'));
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (true) {
      if (await ready.exists()) {
        final acknowledgement = jsonDecode(await ready.readAsString()) as Json;
        if (acknowledgement['nonce'] == nonce) {
          acknowledged = true;
          break;
        }
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('新版启动器未能完成初始化。');
      }
      if (!await _alive(childPid)) throw StateError('新版启动器未能完成初始化。');
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    await completeLauncherUpdateJournal(journalFile, journal);
    await writeJson(resultFile, {'version': plan['version']});
  } catch (error) {
    await writeJson(resultFile, {'error': error.toString()});
    if (oldManifest == null &&
        !await journalFile.exists() &&
        !await _alive(plan['parentPid'] as int)) {
      oldManifest =
          jsonDecode(
                await File(p.join(installation, _manifestName)).readAsString(),
              )
              as Json;
    }
    if (!acknowledged && oldManifest != null) {
      if (childPid != null && await _alive(childPid)) {
        Process.killPid(childPid);
        await _waitForExit(childPid);
      }
      if (journal != null) {
        await _rollback(journal, plan);
        await completeLauncherUpdateJournal(journalFile, journal);
      }
      await _restart(plan, oldManifest);
    }
  } finally {
    if (locked) await lock?.unlock();
    await lock?.close();
  }
}

/// Called before Flutter/window initialization in both normal and helper mode.
Future<void> handleLauncherUpdateMode(List<String> arguments) async {
  final apply = Platform.environment['FYL_APPLY_UPDATE'];
  final recovery = Platform.environment['FYL_RECOVER_UPDATE'];
  if (apply?.isNotEmpty == true || recovery?.isNotEmpty == true) {
    try {
      await _apply(
        apply?.isNotEmpty == true ? apply! : recovery!,
        recoveryParent: recovery?.isNotEmpty == true
            ? int.parse(Platform.environment['FYL_RECOVERY_PARENT']!)
            : null,
      );
      exit(0);
    } catch (_) {
      exit(1);
    }
  }
  final installation = launcherInstallationDirectory();
  final journalFile = File(p.join(installation, _journalName));
  final journal = await readLauncherUpdateJournal(journalFile);
  if (journal == null) return;
  if (journal['phase'] == 'complete') {
    await _clearCompletedJournal(journalFile);
    return;
  }
  // The newly launched process acknowledges this very transaction normally.
  if (Platform.environment['FYL_UPDATE_READY_PLAN'] == journal['plan']) return;
  final planPath = journal['plan'] as String;
  final plan = await _readPlan(planPath);
  if (p.normalize(plan['installation'] as String) !=
      p.normalize(installation)) {
    throw const FormatException('启动器恢复目录不匹配。');
  }
  final manifest =
      jsonDecode(
            await File(
              p.join(plan['payload'] as String, _manifestName),
            ).readAsString(),
          )
          as Json;
  await Process.start(
    safeJoin(plan['payload'] as String, manifest['entrypoint'] as String),
    [],
    workingDirectory: plan['payload'] as String,
    mode: ProcessStartMode.detached,
    environment: {
      'FYL_APPLY_UPDATE': '',
      'FYL_RECOVER_UPDATE': planPath,
      'FYL_RECOVERY_PARENT': '$pid',
      'FYL_UPDATE_READY_PLAN': '',
    },
  );
  exit(0);
}

Future<void> confirmLauncherUpdateStartup(String supportDirectory) async {
  if (_startupConfirmed) return;
  final path = Platform.environment['FYL_UPDATE_READY_PLAN'];
  if (path == null || path.isEmpty) return;
  final journalFile = File(
    p.join(launcherInstallationDirectory(), _journalName),
  );
  final journal = await readLauncherUpdateJournal(journalFile);
  if (journal == null) return;
  if (journal['phase'] == 'complete' || journal['plan'] != path) return;
  final plan = await _readPlan(path);
  if (!p.equals(supportDirectory, plan['dataDirectory'] as String) ||
      !p.equals(
        launcherInstallationDirectory(),
        plan['installation'] as String,
      )) {
    throw const FormatException('启动器更新启动确认路径不匹配。');
  }
  if (launcherVersion != plan['version']) {
    throw const FormatException('启动器更新后的程序版本不匹配。');
  }
  await writeJson(
    File(p.join(p.dirname(path), 'ready-${plan['nonce']}.json')),
    {'nonce': plan['nonce'], 'pid': pid},
  );
  _startupConfirmed = true;
}
