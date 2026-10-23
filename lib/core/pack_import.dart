import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'community_models.dart';
import 'install_options.dart';
import 'models.dart';
import 'network.dart';

class PackEntry {
  final String path;
  final ContentFile? file;
  final String? projectId, fileId;
  final bool optional;
  const PackEntry(
    this.path, {
    this.file,
    this.projectId,
    this.fileId,
    this.optional = false,
  });
}

class PackPlan {
  final String archive, name, version, minecraft;
  final ContentSource source;
  final ModLoader? loader;
  final String? loaderVersion;
  final String? iconEntry;
  final List<PackEntry> files;
  final Map<String, String> overrides;
  const PackPlan({
    required this.archive,
    required this.name,
    required this.version,
    required this.minecraft,
    required this.source,
    required this.files,
    required this.overrides,
    this.loader,
    this.loaderVersion,
    this.iconEntry,
  });
}

String _packPath(String value) {
  safeJoin(Directory.systemTemp.path, value);
  final path = p.posix.normalize(value.replaceAll('\\', '/'));
  if (path == '.' ||
      path.toLowerCase().startsWith('.launcher/') ||
      path.toLowerCase() == '.launcher' ||
      path.toLowerCase().startsWith('.fyl/') ||
      path.toLowerCase() == '.fyl' ||
      path
          .split('/')
          .any(
            (part) =>
                part.contains(':') ||
                part.endsWith('.') ||
                part.endsWith(' ') ||
                RegExp(
                  r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                  caseSensitive: false,
                ).hasMatch(part),
          )) {
    throw FormatException('整合包文件路径无效：$value');
  }
  return path;
}

Future<PackPlan> inspectModpack(String path) =>
    Isolate.run(() => _inspectModpack(path));

Future<PackPlan> _inspectModpack(String path) async {
  final sourceFile = File(path);
  if (await sourceFile.length() > 512 * 1024 * 1024) {
    throw const FormatException('整合包压缩文件超过 512 MB。');
  }
  final input = InputFileStream(path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    if (archive.files.length > 40000) {
      throw const FormatException('整合包文件数量超过限制。');
    }
    var expanded = 0;
    final names = <String>{};
    for (final entry in archive.files) {
      if (entry.isSymbolicLink) throw const FormatException('整合包不支持符号链接。');
      final name = _packPath(entry.name.replaceAll(RegExp(r'[/\\]+$'), ''));
      if (!names.add(name.toLowerCase())) {
        throw FormatException('整合包包含重复文件：$name');
      }
      expanded += entry.size;
      if (expanded > 2 * 1024 * 1024 * 1024 || entry.size > 256 * 1024 * 1024) {
        throw const FormatException('整合包解压大小超过限制。');
      }
    }
    ArchiveFile? manifest;
    for (final name in ['modrinth.index.json', 'manifest.json']) {
      manifest = archive.findFile(name);
      if (manifest != null) break;
    }
    manifest ??= archive.files
        .where(
          (entry) =>
              entry.isFile &&
              entry.name.split('/').length == 2 &&
              [
                'modrinth.index.json',
                'manifest.json',
              ].contains(entry.name.split('/').last),
        )
        .firstOrNull;
    if (manifest == null || manifest.size > 4 * 1024 * 1024) {
      throw const FormatException('没有找到受支持的 Modrinth 或 CurseForge 整合包清单。');
    }
    final json = jsonDecode(utf8.decode(manifest.content)) as Json;
    final isModrinth = manifest.name.endsWith('modrinth.index.json');
    final prefix = manifest.name.substring(
      0,
      manifest.name.length - manifest.name.split('/').last.length,
    );
    final files = <PackEntry>[];
    final dependencies = <String, String>{};
    if (isModrinth) {
      if (json['formatVersion'] != 1 || json['game'] != 'minecraft') {
        throw const FormatException('不支持此整合包格式版本。');
      }
      dependencies.addAll(
        Map<String, String>.from(json['dependencies'] as Map),
      );
      for (final raw in json['files'] as List) {
        final row = raw as Json;
        final relative = _packPath(row['path'] as String);
        if (row['env']?['client'] == 'unsupported') continue;
        final hashes = Map<String, String>.from(row['hashes'] as Map);
        if (!RegExp(r'^[a-fA-F0-9]{40}$').hasMatch(hashes['sha1'] ?? '') ||
            !RegExp(r'^[a-fA-F0-9]{128}$').hasMatch(hashes['sha512'] ?? '')) {
          throw FormatException('整合包文件缺少有效校验信息：$relative');
        }
        final urls = List<String>.from(row['downloads'] as List);
        if (urls.isEmpty) throw FormatException('整合包文件没有下载地址：$relative');
        files.add(
          PackEntry(
            relative,
            optional: row['env']?['client'] == 'optional',
            file: ContentFile(
              name: p.posix.basename(relative),
              urls: urls,
              hashes: {'sha1': hashes['sha1']!, 'sha512': hashes['sha512']!},
              size: (row['fileSize'] as num).toInt(),
            ),
          ),
        );
      }
    } else {
      if (json['manifestType'] != 'minecraftModpack' ||
          json['manifestVersion'] != 1) {
        throw const FormatException('不支持此 CurseForge 清单格式。');
      }
      dependencies['minecraft'] = json['minecraft']['version'] as String;
      final loaders = (json['minecraft']['modLoaders'] as List? ?? [])
          .cast<Json>();
      if (loaders.where((v) => v['primary'] == true).length > 1) {
        throw const FormatException('整合包声明了多个主加载器。');
      }
      final selected = loaders.firstWhere(
        (v) => v['primary'] == true,
        orElse: () => loaders.isEmpty ? <String, dynamic>{} : loaders.first,
      );
      if (selected.isNotEmpty) {
        final id = selected['id'] as String;
        final kind = [
          'neoforge',
          'forge',
          'fabric-loader',
          'fabric',
          'quilt-loader',
          'quilt',
        ].firstWhere((kind) => id.startsWith('$kind-'), orElse: () => '');
        if (kind.isEmpty) throw FormatException('不支持整合包加载器：$id');
        dependencies[switch (kind) {
          'fabric' => 'fabric-loader',
          'quilt' => 'quilt-loader',
          _ => kind,
        }] = id.substring(
          kind.length + 1,
        );
      }
      for (final row in json['files'] as List) {
        if (row['projectID'] is! int ||
            row['fileID'] is! int ||
            (row['projectID'] as int) <= 0 ||
            (row['fileID'] as int) <= 0) {
          throw const FormatException('整合包中的 CurseForge 项目或文件 ID 无效。');
        }
        files.add(
          PackEntry(
            '',
            projectId: '${row['projectID']}',
            fileId: '${row['fileID']}',
            optional: row['required'] == false,
          ),
        );
      }
    }
    if (files.length > 10000) throw const FormatException('整合包下载文件数量超过限制。');
    final minecraft = dependencies.remove('minecraft');
    if (minecraft == null || minecraft.isEmpty) {
      throw const FormatException('整合包未指定 Minecraft 版本。');
    }
    if (dependencies.keys.any(
      (key) =>
          !['forge', 'neoforge', 'fabric-loader', 'quilt-loader'].contains(key),
    )) {
      throw FormatException('暂不支持整合包所需组件：${dependencies.keys.join(', ')}');
    }
    if (dependencies.length > 1) throw const FormatException('整合包声明了多个互斥的加载器。');
    final loader = dependencies.isEmpty
        ? null
        : switch (dependencies.keys.single) {
            'forge' => ModLoader.forge,
            'neoforge' => ModLoader.neoforge,
            'quilt-loader' => ModLoader.quilt,
            _ => ModLoader.fabric,
          };
    final overrides = <String, String>{};
    final directories = [
      isModrinth
          ? 'overrides'
          : _packPath(json['overrides'] as String? ?? 'overrides'),
      if (isModrinth) 'client-overrides',
    ];
    for (final directory in directories) {
      final base = '$prefix$directory/';
      for (final entry in archive.files) {
        if (entry.isFile && entry.name.startsWith(base)) {
          final relative = _packPath(entry.name.substring(base.length));
          final existing = overrides.keys
              .where((key) => key.toLowerCase() == relative.toLowerCase())
              .firstOrNull;
          if (existing != null && existing != relative) {
            throw FormatException('文件路径大小写冲突：$relative');
          }
          overrides[relative] = entry.name;
        }
      }
    }
    final paths = <String>{};
    for (final entry in files.where((f) => f.path.isNotEmpty)) {
      if (!paths.add(entry.path.toLowerCase())) {
        throw const FormatException('整合包声明了重复下载路径。');
      }
    }
    return PackPlan(
      archive: path,
      source: isModrinth ? ContentSource.modrinth : ContentSource.curseforge,
      name: json['name'] as String,
      version: '${json[isModrinth ? 'versionId' : 'version'] ?? ''}',
      minecraft: minecraft,
      files: files,
      overrides: overrides,
      loader: loader,
      loaderVersion: dependencies.isEmpty ? null : dependencies.values.single,
      iconEntry: ['icon.png', 'pack.png', 'modpack.png']
          .map((name) => '$prefix$name')
          .where((name) {
            final icon = archive.findFile(name);
            return icon != null && icon.isFile && icon.size <= 8 * 1024 * 1024;
          })
          .firstOrNull,
    );
  } finally {
    input.close();
  }
}

Future<void> extractPackOverrides(
  PackPlan plan,
  String destination,
  CancellationToken token, {
  String? iconDestination,
}) async {
  token.check();
  final events = ReceivePort();
  SendPort? control;
  void cancel() => control?.send(null);
  final subscription = events.listen((message) {
    control = message as SendPort;
    if (token.cancelled) cancel();
  });
  token.add(cancel);
  try {
    await _startPackExtraction(
      plan,
      destination,
      iconDestination,
      events.sendPort,
    );
    token.check();
  } finally {
    token.remove(cancel);
    await subscription.cancel();
    events.close();
  }
}

// Keep the isolate closure separate from the UI-side cancellation/receive ports.
Future<void> _startPackExtraction(
  PackPlan plan,
  String destination,
  String? iconDestination,
  SendPort events,
) => Isolate.run(() async {
  final control = ReceivePort();
  final token = CancellationToken();
  final subscription = control.listen((_) => token.cancel());
  events.send(control.sendPort);
  try {
    await _extractPackOverrides(
      plan,
      destination,
      token,
      iconDestination: iconDestination,
    );
  } finally {
    await subscription.cancel();
    control.close();
  }
});

Future<void> _extractPackOverrides(
  PackPlan plan,
  String destination,
  CancellationToken token, {
  String? iconDestination,
}) async {
  final input = InputFileStream(plan.archive);
  try {
    final archive = ZipDecoder().decodeStream(input);
    if (iconDestination != null && plan.iconEntry != null) {
      token.check();
      final icon = archive.findFile(plan.iconEntry!);
      if (icon != null &&
          icon.isFile &&
          !icon.isSymbolicLink &&
          icon.size <= 8 * 1024 * 1024) {
        await File(iconDestination).parent.create(recursive: true);
        await File(iconDestination).writeAsBytes(icon.content, flush: true);
      }
    }
    for (final entry in plan.overrides.entries) {
      token.check();
      final source = archive.findFile(entry.value);
      if (source == null || !source.isFile || source.isSymbolicLink) {
        throw const FormatException('整合包覆盖文件无效。');
      }
      final target = File(safeJoin(destination, entry.key));
      await ensurePackParents(destination, target.path);
      await target.writeAsBytes(source.content, flush: true);
    }
  } finally {
    input.close();
  }
}

Future<void> ensurePackParents(String root, String target) async {
  var current = target;
  while (p.isWithin(root, current)) {
    if (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('目标目录中存在符号链接，无法安全安装整合包。');
    }
    current = p.dirname(current);
  }
  await File(target).parent.create(recursive: true);
}
