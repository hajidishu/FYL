import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'build_info.dart';
import 'models.dart';
import 'version_logs.dart';

class GameFailure {
  final String instanceId, instanceName;
  String logPath;
  final int exitCode;
  final Map<String, String> files;
  final List<String> _secrets;
  GameFailure({
    required this.instanceId,
    required this.instanceName,
    required this.logPath,
    required this.exitCode,
    required this.files,
    List<String> secrets = const [],
  }) : _secrets = secrets;

  Future<void> exportReport(String destination) async {
    final contents = files;
    final secrets = _secrets;
    final bytes = await Isolate.run(() {
      final archive = Archive();
      for (final entry in contents.entries) {
        if (!{
          'report.txt',
          'launcher.log',
          'minecraft-latest.log',
          'minecraft-crash-report.txt',
          'jvm-error.log',
        }.contains(entry.key)) {
          throw const FormatException('错误报告包含不支持的文件。');
        }
        final data = utf8.encode(sanitizeDiagnosticText(entry.value, secrets));
        archive.addFile(ArchiveFile(entry.key, data.length, data));
      }
      return ZipEncoder().encode(archive);
    });
    if (await FileSystemEntity.type(destination, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('导出目标不能是符号链接。');
    }
    await File(destination).writeAsBytes(bytes, flush: true);
  }

  Future<void> exportLog(String destination) async {
    final secrets = _secrets;
    if (await File(logPath).exists()) {
      await exportSanitizedLog(logPath, destination, secrets: secrets);
    } else {
      if (await FileSystemEntity.type(destination, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('导出目标不能是符号链接。');
      }
      final text = files['launcher.log'] ?? '';
      await Isolate.run(
        () => File(
          destination,
        ).writeAsString(sanitizeDiagnosticText(text, secrets), flush: true),
      );
    }
  }
}

String sanitizeDiagnosticText(String text, [List<String> secrets = const []]) {
  text = text.replaceAll(
    RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)',
    ),
    '[已隐藏私钥]',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'(Authorization\s*[:=]\s*Basic\s+)[A-Za-z0-9+/=]+',
      caseSensitive: false,
    ),
    (match) => '${match[1]}[已隐藏凭据]',
  );
  final values = secrets.where((value) => value.length >= 4).toSet().toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final value in values) {
    text = text.replaceAll(value, '[已隐藏凭据]');
  }
  text = text.replaceAll(
    RegExp(r'Bearer\s+[^\s"<>]+', caseSensitive: false),
    'Bearer [已隐藏凭据]',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'''((?:access[_-]?token|refresh[_-]?token|client[_-]?secret|api[_-]?key|password|passwd)["']?\s*(?:[:=]|\s)\s*)["']?[^\s"'<>&,]+''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}[已隐藏凭据]',
  );
  text = text.replaceAll(
    RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
    '[已隐藏凭据]',
  );
  text = text.replaceAllMapped(
    RegExp(r'(https?://)[^\s/:]+:[^\s/@]+@'),
    (match) => '${match[1]}[已隐藏凭据]@',
  );
  for (final key in ['USERPROFILE', 'HOME']) {
    final home = Platform.environment[key];
    if (home == null || home.length < 3) continue;
    for (final value in {
      home,
      home.replaceAll('\\', '/'),
      home.replaceAll('/', '\\'),
    }) {
      text = text.replaceAll(
        RegExp(RegExp.escape(value), caseSensitive: !Platform.isWindows),
        '[用户目录]',
      );
    }
  }
  return text;
}

Future<void> exportSanitizedLog(
  String source,
  String destination, {
  List<String> secrets = const [],
}) async {
  if (await FileSystemEntity.type(source, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException('原始日志不存在或不是普通文件。');
  }
  if (p.equals(p.absolute(source), p.absolute(destination)) ||
      await File(destination).exists() &&
          await FileSystemEntity.identical(source, destination)) {
    throw const FormatException('请选择其他文件位置，避免覆盖原始日志。');
  }
  if (await FileSystemEntity.type(destination, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException('导出目标不能是符号链接。');
  }
  await Isolate.run(() async {
    final file = File(source);
    final length = await file.length();
    final sink = File(destination).openWrite();
    var privateKey = false;
    try {
      await for (final line
          in file
              .openRead(0, length)
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        if (RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----').hasMatch(line)) {
          privateKey = true;
          sink.writeln('[已隐藏私钥]');
        }
        if (privateKey) {
          if (RegExp(r'-----END [A-Z ]*PRIVATE KEY-----').hasMatch(line)) {
            privateKey = false;
          }
          continue;
        }
        sink.writeln(sanitizeDiagnosticText(line, secrets));
      }
    } finally {
      await sink.close();
    }
  });
}

Future<GameFailure> captureGameFailure({
  required GameInstance instance,
  required VersionLog log,
  required HostPlatform platform,
  required String java,
  required int minMemory,
  required int maxMemory,
  required int exitCode,
  int? pid,
  bool includeGameLogs = true,
  List<String> secrets = const [],
}) async {
  final logPath = log.path;
  final startedAt = log.startedAt;
  final endedAt = log.endedAt ?? DateTime.now();
  return Isolate.run(() async {
    final files = <String, String>{};
    Future<String?> read(
      String path,
      String root,
      int limit, {
      bool ownSession = false,
    }) async {
      try {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
          return null;
        }
        final resolvedRoot = await Directory(root).resolveSymbolicLinks();
        final resolved = await File(path).resolveSymbolicLinks();
        if (!p.isWithin(resolvedRoot, resolved)) return null;
        final file = File(resolved);
        final before = await file.stat();
        if (ownSession &&
            (before.modified.isBefore(startedAt) ||
                before.modified.isAfter(endedAt))) {
          return null;
        }
        final length = await file.length();
        final start = (length - limit).clamp(0, length);
        final bytes = await file
            .openRead(start)
            .fold(<int>[], (data, chunk) => data..addAll(chunk));
        final after = await file.stat();
        if (ownSession &&
            (after.modified != before.modified || after.size != before.size)) {
          return null;
        }
        final prefix = start > 0
            ? '[日志过长，报告仅保留末尾 $limit 字节；可单独导出完整启动日志]\n'
            : '';
        return sanitizeDiagnosticText(
          prefix + utf8.decode(bytes, allowMalformed: true),
          secrets,
        );
      } on FileSystemException {
        return null;
      }
    }

    final own = await read(logPath, instance.versionDirectory, 4 * 1024 * 1024);
    if (own != null) files['launcher.log'] = own;
    if (includeGameLogs) {
      final latestFile = File(
        p.join(instance.gameDirectory, 'logs', 'latest.log'),
      );
      if (await latestFile.exists() &&
          !(await latestFile.stat()).modified.isBefore(startedAt)) {
        final latest = await read(
          latestFile.path,
          instance.gameDirectory,
          2 * 1024 * 1024,
          ownSession: true,
        );
        if (latest != null) files['minecraft-latest.log'] = latest;
      }
      final crashes = Directory(
        p.join(instance.gameDirectory, 'crash-reports'),
      );
      if (await FileSystemEntity.type(crashes.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        final candidates = <(File, DateTime)>[];
        await for (final file in crashes.list(followLinks: false)) {
          if (file is! File || !file.path.endsWith('.txt')) continue;
          final modified = (await file.stat()).modified;
          if (!modified.isBefore(startedAt)) candidates.add((file, modified));
        }
        candidates.sort((a, b) => b.$2.compareTo(a.$2));
        if (candidates.isNotEmpty) {
          final crash = await read(
            candidates.first.$1.path,
            instance.gameDirectory,
            2 * 1024 * 1024,
            ownSession: true,
          );
          if (crash != null) files['minecraft-crash-report.txt'] = crash;
        }
      }
    }
    if (pid != null) {
      final jvm = await read(
        p.join(instance.gameDirectory, 'hs_err_pid$pid.log'),
        instance.gameDirectory,
        2 * 1024 * 1024,
        ownSession: true,
      );
      if (jvm != null) files['jvm-error.log'] = jvm;
    }
    final mods = Directory(p.join(instance.gameDirectory, 'mods'));
    final names = <String>[];
    if (await FileSystemEntity.type(mods.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await for (final file in mods.list(followLinks: false)) {
        if (file is File &&
            (file.path.endsWith('.jar') ||
                file.path.endsWith('.jar.disabled'))) {
          names.add(p.basename(file.path));
          if (names.length == 5000) break;
        }
      }
      names.sort();
    }
    files['report.txt'] = sanitizeDiagnosticText(
      'FYL 错误报告\n'
      'FYL: $launcherVersion\n'
      '版本名称: ${instance.name}\n'
      'Minecraft: ${instance.version}\n'
      '组件: ${instance.components.isEmpty ? '原版' : instance.components}\n'
      '系统: ${platform.os} / ${platform.arch} / ${platform.osVersion}\n'
      '启动时间: ${startedAt.toIso8601String()}\n'
      '退出时间: ${endedAt.toIso8601String()}\n'
      '退出码: $exitCode\n'
      'Java: $java\n'
      '内存: $minMemory–$maxMemory MB\n'
      '${includeGameLogs ? '' : '同目录存在其他启动会话，仅收录本客户端日志，避免混入其他客户端的输出。\n'}'
      '\nMod (${names.length}):\n${names.join('\n')}\n',
      secrets,
    );
    return GameFailure(
      instanceId: instance.id,
      instanceName: instance.name,
      logPath: logPath,
      exitCode: exitCode,
      files: files,
      secrets: secrets,
    );
  });
}
