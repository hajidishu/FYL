import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'game_log.dart';
import 'minecraft.dart' show writeJson;
import 'models.dart';

class VersionLog {
  String path;
  final DateTime startedAt;
  final String? gameDirectory;
  DateTime? endedAt;
  int? exitCode;
  final lines = <String>[];
  VersionLog(
    this.path,
    this.startedAt, {
    this.endedAt,
    this.exitCode,
    this.gameDirectory,
  });

  void append(String line) {
    lines.add(line);
    if (lines.length > 600) lines.removeRange(0, lines.length - 600);
  }
}

final _ownedLogName = RegExp(r'^\d{13,20}(?:-\d+)?\.log$');

Future<void> ensureVersionLogDirectory(GameInstance instance) async {
  for (final directory in [
    instance.launcherDirectory,
    p.join(instance.launcherDirectory, 'logs'),
  ]) {
    final type = await FileSystemEntity.type(directory, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FormatException('日志目录不能是符号链接或文件。');
    }
    await Directory(directory).create(recursive: true);
  }
}

Future<bool> _regularLogDirectory(String directory) async =>
    await FileSystemEntity.type(p.dirname(directory), followLinks: false) ==
        FileSystemEntityType.directory &&
    await FileSystemEntity.type(directory, followLinks: false) ==
        FileSystemEntityType.directory;

Future<void> saveLatestLog(GameInstance instance, VersionLog log) =>
    writeJson(File(p.join(instance.launcherDirectory, 'logs', 'latest.json')), {
      'file': p.basename(log.path),
      'startedAt': log.startedAt.toIso8601String(),
      'endedAt': log.endedAt?.toIso8601String(),
      'exitCode': log.exitCode,
    });

Future<VersionLog?> readLatestLog(GameInstance instance) async {
  final directory = p.join(instance.launcherDirectory, 'logs');
  if (!await _regularLogDirectory(directory)) return null;
  final metadata = File(p.join(directory, 'latest.json'));
  try {
    if (await FileSystemEntity.type(metadata.path, followLinks: false) ==
        FileSystemEntityType.file) {
      final json = jsonDecode(await metadata.readAsString()) as Json;
      final name = json['file'] as String;
      if (_ownedLogName.hasMatch(name)) {
        final path = p.join(directory, name);
        if (await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.file) {
          return VersionLog(
            path,
            DateTime.parse(json['startedAt'] as String),
            endedAt: DateTime.tryParse(json['endedAt'] as String? ?? ''),
            exitCode: json['exitCode'] as int?,
            gameDirectory: instance.gameDirectory,
          );
        }
      }
    }
  } catch (_) {
    // A partial metadata file must not hide the existing launch log.
  }
  final files = await _logFiles(directory);
  if (files.isEmpty) return null;
  return VersionLog(
    files.first.path,
    DateTime.fromMillisecondsSinceEpoch(_stamp(files.first.path)),
    gameDirectory: instance.gameDirectory,
  );
}

int _stamp(String path) =>
    int.parse(p.basename(path).split(RegExp(r'[-.]')).first);

Future<List<File>> _logFiles(String directory) async {
  if (!await _regularLogDirectory(directory)) return [];
  final files = <File>[];
  await for (final entry in Directory(directory).list(followLinks: false)) {
    if (entry is File && _ownedLogName.hasMatch(p.basename(entry.path))) {
      files.add(entry);
    }
  }
  int order(File file) =>
      int.tryParse(
        RegExp(r'-(\d+)\.log$').firstMatch(file.path)?.group(1) ?? '',
      ) ??
      0;
  files.sort((a, b) {
    final stamp = _stamp(b.path).compareTo(_stamp(a.path));
    return stamp != 0 ? stamp : order(b).compareTo(order(a));
  });
  return files;
}

Future<void> pruneVersionLogs(
  GameInstance instance,
  int retain,
  Set<String> activePaths,
) async {
  final files = await _logFiles(p.join(instance.launcherDirectory, 'logs'));
  for (final file in files.skip(retain)) {
    if (activePaths.any((path) => p.equals(path, file.path))) continue;
    try {
      await file.delete();
    } on FileSystemException {
      // Another client or a log reader may still hold the file open.
    }
  }
}

Future<List<String>> loadLogLines(String path) => Isolate.run(() async {
  final file = File(path);
  final length = await file.length();
  const limit = 512 * 1024;
  final start = (length - limit).clamp(0, length);
  final bytes = await file
      .openRead(start)
      .fold(<int>[], (all, chunk) => all..addAll(chunk));
  var text = utf8.decode(bytes, allowMalformed: true);
  if (start > 0 && text.contains('\n')) {
    text = text.substring(text.indexOf('\n') + 1);
  }
  final formatter = GameLogFormatter();
  final lines = const LineSplitter()
      .convert(text)
      .map(formatter.format)
      .whereType<String>()
      .where((line) => line.isNotEmpty)
      .toList();
  return lines.skip((lines.length - 600).clamp(0, lines.length)).toList();
});
