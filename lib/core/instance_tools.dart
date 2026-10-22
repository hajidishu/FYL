import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'install_options.dart';
import 'minecraft.dart';
import 'mod_catalog.dart';
import 'models.dart';
import 'network.dart';
import 'pack_import.dart';

Future<ProcessResult> runPreLaunchCommand(
  String command,
  String directory,
  HostPlatform platform, {
  Duration timeout = const Duration(minutes: 2),
}) async {
  final process = await Process.start(
    platform.os == 'windows' ? 'cmd.exe' : '/bin/sh',
    platform.os == 'windows' ? ['/d', '/s', '/c', command] : ['-c', command],
    workingDirectory: directory,
  );
  await process.stdin.close();
  final output = StringBuffer(), errors = StringBuffer();
  void append(StringBuffer target, String value) {
    if (target.length < 32768) {
      target.write(
        value.substring(0, value.length.clamp(0, 32768 - target.length)),
      );
    }
  }

  final outDone = Completer<void>(), errDone = Completer<void>();
  final outSubscription = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(
        (v) => append(output, v),
        onDone: outDone.complete,
        onError: outDone.completeError,
      );
  final errSubscription = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen(
        (v) => append(errors, v),
        onDone: errDone.complete,
        onError: errDone.completeError,
      );
  try {
    final result = await Future.wait<Object?>([
      process.exitCode,
      outDone.future,
      errDone.future,
    ]).timeout(timeout);
    return ProcessResult(
      process.pid,
      result.first as int,
      output.toString(),
      errors.toString(),
    );
  } on TimeoutException {
    if (platform.os == 'windows') {
      try {
        await Process.run('taskkill.exe', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {
        /* Fall back to terminating the shell itself. */
      }
    }
    process.kill();
    throw StateError('启动前命令运行超时，已停止等待。');
  } finally {
    await outSubscription.cancel();
    await errSubscription.cancel();
  }
}

Future<InstallOptions> instanceInstallOptions(
  GameInstance instance,
  OfficialNetwork network,
  CancellationToken token,
) async {
  if (instance.installation.isNotEmpty) {
    return InstallOptions.fromJson(instance.installation);
  }
  LoaderVersion? loader;
  for (final type in ModLoader.values) {
    final match = RegExp(
      '(?:^| · )${type.label} ([^ ·]+)',
    ).firstMatch(instance.components);
    if (match == null) continue;
    final all = await ModCatalog(
      network,
    ).loaders(type, instance.version, token);
    loader = all.where((v) => v.version == match[1]).firstOrNull;
    if (loader == null) {
      throw StateError('找不到此版本使用的 ${type.label} ${match[1]}。');
    }
  }
  OptiFineVersion? optifine;
  CompatibilityMod? optifabric;
  if (instance.components.contains('OptiFine')) {
    final cache = Directory(p.join(instance.root, 'installers'));
    final choices = <File>[];
    if (await cache.exists()) {
      await for (final entry in cache.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is File &&
            RegExp(
              '^(?:preview_)?OptiFine_${RegExp.escape(instance.version)}_.*\\.jar\$',
            ).hasMatch(p.basename(entry.path))) {
          choices.add(entry);
        }
      }
    }
    final names = choices.map((f) => p.basename(f.path)).toSet();
    if (names.length != 1) throw StateError('旧版本缺少精确的 OptiFine 安装记录，无法自动修复。');
    optifine = OptiFineVersion(names.single, localPath: choices.first.path);
    if (instance.components.contains('OptiFabric')) {
      final match = RegExp(
        r'OptiFabric ([^ ·]+)',
      ).firstMatch(instance.components);
      final all = await ModCatalog(network).optifabric(instance.version, token);
      optifabric = all.where((v) => v.version == match?[1]).firstOrNull;
      if (optifabric == null) throw StateError('找不到此版本使用的 OptiFabric。');
    }
  }
  return InstallOptions(
    loader: loader,
    optifine: optifine,
    optifabric: optifabric,
  );
}

String launchScript(
  LaunchCommand command,
  HostPlatform platform, {
  String preLaunchCommand = '',
}) {
  if (platform.os == 'windows') {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    return '\uFEFF\$ErrorActionPreference = \'Stop\'\r\n'
        'Set-Location -LiteralPath ${quote(command.workingDirectory)}\r\n'
        '${preLaunchCommand.trim().isEmpty ? '' : "& cmd.exe /d /s /c ${quote(preLaunchCommand)}\r\nif (\$LASTEXITCODE -ne 0) { exit \$LASTEXITCODE }\r\n"}'
        '& ${quote(command.executable)} @(\r\n${command.arguments.map((a) => '  ${quote(a)}').join(',\r\n')}\r\n)\r\n'
        'exit \$LASTEXITCODE\r\n';
  }
  String quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
  return '#!/bin/sh\nset -e\ncd ${quote(command.workingDirectory)}\n'
      '${preLaunchCommand.trim().isEmpty ? '' : '/bin/sh -c ${quote(preLaunchCommand)}\n'}'
      'exec ${quote(command.executable)} ${command.arguments.map(quote).join(' ')}\n';
}

const exportFolders = {
  'mods': 'Mod 文件',
  'config': '模组配置',
  'defaultconfigs': '默认配置',
  'resourcepacks': '资源包',
  'shaderpacks': '光影包',
  'kubejs': 'KubeJS 脚本',
  'scripts': '整合包脚本',
  'saves': '游戏存档',
};
const exportDefaults = {
  'mods',
  'config',
  'defaultconfigs',
  'resourcepacks',
  'shaderpacks',
  'kubejs',
  'scripts',
};

/// A standard mrpack with local content in overrides; no account/global config.
Future<int> exportInstancePack(
  GameInstance instance,
  String destination,
  CancellationToken token, {
  required Set<String> folders,
  required String version,
  bool gameOptions = true,
  void Function(int, int)? onProgress,
}) async {
  if (version.trim().isEmpty) throw ArgumentError('请填写整合包版本号。');
  final root = p.normalize(p.absolute(instance.gameDirectory));
  if (await FileSystemEntity.type(root, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException('游戏目录不能是符号链接。');
  }
  final output = p.normalize(p.absolute(destination));
  if (p.equals(root, output) || p.isWithin(root, output)) {
    throw ArgumentError('请将整合包保存到当前游戏目录以外。');
  }
  final dependencies = <String, String>{'minecraft': instance.version};
  final recipe = instance.installation['loader'] as Json?;
  if (recipe != null) {
    dependencies[switch (recipe['type']) {
          'fabric' => 'fabric-loader',
          'quilt' => 'quilt-loader',
          _ => recipe['type'] as String,
        }] =
        recipe['version'] as String;
  } else {
    for (final type in ModLoader.values) {
      final match = RegExp(
        '(?:^| · )${type.label} ([^ ·]+)',
      ).firstMatch(instance.components);
      if (match != null) {
        dependencies[switch (type) {
              ModLoader.fabric => 'fabric-loader',
              ModLoader.quilt => 'quilt-loader',
              _ => type.name,
            }] =
            match[1]!;
      }
    }
  }
  if (instance.components.contains('OptiFine') && dependencies.length == 1) {
    throw StateError('独立 OptiFine 启动配置无法表示为标准 mrpack，请使用带加载器的版本导出。');
  }
  final files = <File>[];
  for (final folder in folders) {
    if (!exportFolders.containsKey(folder)) throw ArgumentError('导出目录无效。');
    final directory = Directory(safeJoin(root, folder));
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('导出目录不能是符号链接：$folder');
    }
    if (!await directory.exists()) continue;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      token.check();
      if (entry is Link) {
        throw StateError('导出内容包含符号链接：${p.relative(entry.path, from: root)}');
      }
      if (entry is File &&
          !entry.path.endsWith('.fyl-part') &&
          p.basename(entry.path) != '.fyl-managed-mods.json') {
        files.add(entry);
      }
    }
  }
  if (gameOptions) {
    final options = File(p.join(root, 'options.txt'));
    if (await FileSystemEntity.type(options.path, followLinks: false) ==
        FileSystemEntityType.file) {
      files.add(options);
    }
  }
  if (files.length > 39000) throw StateError('文件数量超过整合包限制。');
  var size = 0;
  for (final file in files) {
    token.check();
    final length = await file.length();
    if (length > 256 * 1024 * 1024) {
      throw StateError('单个文件超过 256 MB：${p.basename(file.path)}');
    }
    size += length;
  }
  if (size > 2 * 1024 * 1024 * 1024) throw StateError('导出内容超过 2 GB，请减少所选项目。');
  await File(output).parent.create(recursive: true);
  final temporary = '$output.fyl-part';
  final encoder = ZipFileEncoder()..create(temporary);
  try {
    final index = utf8.encode(
      jsonEncode({
        'formatVersion': 1,
        'game': 'minecraft',
        'name': instance.name,
        'versionId': version.trim(),
        'summary': instance.description,
        'dependencies': dependencies,
        'files': [],
      }),
    );
    encoder.addArchiveFile(
      ArchiveFile('modrinth.index.json', index.length, index),
    );
    for (var i = 0; i < files.length; i++) {
      token.check();
      final relative = p
          .relative(files[i].path, from: root)
          .replaceAll('\\', '/');
      await encoder.addFile(files[i], 'overrides/$relative');
      onProgress?.call(i + 1, files.length);
      await Future<void>.delayed(Duration.zero);
    }
  } catch (_) {
    await encoder.close();
    if (await File(temporary).exists()) await File(temporary).delete();
    rethrow;
  }
  try {
    await encoder.close();
    token.check();
    if (await File(temporary).length() > 512 * 1024 * 1024) {
      throw StateError('压缩后超过 512 MB，无法作为 FYL 整合包导入，请减少内容。');
    }
    await File(temporary).rename(output);
    return files.length;
  } finally {
    if (await File(temporary).exists()) await File(temporary).delete();
  }
}

Future<void> copyInstanceData(
  GameInstance original,
  GameInstance updated,
  CancellationToken token,
) async {
  final source = Directory(original.gameDirectory);
  final target = Directory(updated.gameDirectory);
  for (final directory in [source, target]) {
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('游戏目录不能是符号链接。');
    }
  }
  if (!await source.exists()) {
    await target.create(recursive: true);
    return;
  }
  final items = <(File, String)>[];
  await for (final entry in source.list(followLinks: false)) {
    token.check();
    final name = p.basename(entry.path);
    if (!isGameDataPath(name, original)) continue;
    if (entry is Link) throw const FormatException('游戏数据包含符号链接，无法自动迁移。');
    if (entry is File) {
      items.add((
        entry,
        safeJoin(target.path, p.relative(entry.path, from: source.path)),
      ));
    } else if (entry is Directory) {
      await for (final child in entry.list(
        recursive: true,
        followLinks: false,
      )) {
        token.check();
        if (child is Link) throw const FormatException('游戏数据包含符号链接，无法自动迁移。');
        if (child is File) {
          items.add((
            child,
            safeJoin(target.path, p.relative(child.path, from: source.path)),
          ));
        }
      }
    }
  }
  final planned = <(File, String)>[];
  for (final item in items) {
    token.check();
    final type = await FileSystemEntity.type(item.$2, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type == FileSystemEntityType.file &&
          await item.$1.length() == await File(item.$2).length() &&
          (await sha1.bind(item.$1.openRead()).first).toString() ==
              (await sha1.bind(File(item.$2).openRead()).first).toString()) {
        continue;
      }
      throw StateError(
        '目标目录存在不同的同名文件：${p.relative(item.$2, from: target.path)}。原文件未修改。',
      );
    }
    planned.add(item);
  }
  final created = <File>[];
  try {
    for (final (file, path) in planned) {
      token.check();
      await ensurePackParents(target.path, path);
      created.add(await file.copy(path));
    }
  } catch (_) {
    for (final file in created) {
      if (await file.exists()) await file.delete();
    }
    rethrow;
  }
}

bool isGameDataPath(String relative, GameInstance instance) {
  final name = relative.replaceAll('\\', '/').split('/').first.toLowerCase();
  if ({
    'versions',
    'assets',
    'libraries',
    'runtime',
    'installers',
    '.fyl',
    '.fyl-trash',
    '.launcher',
    'launcher_accounts.json',
    'launcher_profiles.json',
    'launcher_profiles_microsoft_store.json',
  }.contains(name)) {
    return false;
  }
  if (instance.isolated &&
      {
        '${instance.name.toLowerCase()}.json',
        '${instance.name.toLowerCase()}.json.bak',
        '${instance.name.toLowerCase()}.json.tmp',
        '${instance.name.toLowerCase()}.jar',
      }.contains(name)) {
    return false;
  }
  return true;
}

Future<bool> renameVersionDirectory(
  GameInstance previous,
  GameInstance updated,
) async {
  final source = previous.versionDirectory,
      destination = updated.versionDirectory;
  final invalid = validateVersionName(updated.name);
  if (invalid != null) throw ArgumentError(invalid);
  final sourceType = await FileSystemEntity.type(source, followLinks: false);
  if (sourceType == FileSystemEntityType.link) {
    throw const FormatException('版本文件夹不能是符号链接。');
  }
  final destinationType = await FileSystemEntity.type(
    destination,
    followLinks: false,
  );
  // Case sensitivity belongs to the filesystem, including macOS APFS volumes.
  final sameDirectory =
      sourceType == FileSystemEntityType.directory &&
      destinationType == FileSystemEntityType.directory &&
      await FileSystemEntity.identical(source, destination);
  if (!sameDirectory && destinationType != FileSystemEntityType.notFound) {
    throw StateError('版本文件夹“${updated.name}”已存在。');
  }
  if (!await Directory(source).exists()) return false;
  final staging = safeJoin(
    p.join(previous.root, '.fyl', 'renames'),
    '${DateTime.now().microsecondsSinceEpoch}',
  );
  await ensurePackParents(previous.root, staging);
  await Directory(source).rename(staging);
  final renamed = <(String, String)>[];
  String? originalJson;
  try {
    for (final suffix in ['.json', '.jar', '.json.bak']) {
      final oldFile = File(safeJoin(staging, '${previous.name}$suffix'));
      if (!await oldFile.exists()) continue;
      if (suffix == '.json') originalJson = await oldFile.readAsString();
      final target = safeJoin(staging, '${updated.name}$suffix');
      await oldFile.rename(target);
      renamed.add((oldFile.path, target));
    }
    if (originalJson != null) {
      final json = jsonDecode(originalJson) as Json;
      json['id'] = updated.name;
      await File(safeJoin(staging, '${updated.name}.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
    }
    await Directory(staging).rename(destination);
    return true;
  } catch (_) {
    for (final item in renamed.reversed) {
      await File(item.$2).rename(item.$1);
    }
    if (originalJson != null) {
      await File(
        safeJoin(staging, '${previous.name}.json'),
      ).writeAsString(originalJson, flush: true);
    }
    await Directory(staging).rename(source);
    rethrow;
  }
}
