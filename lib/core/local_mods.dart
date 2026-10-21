import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'network.dart';
import 'pack_import.dart';
import 'file_transaction.dart';

void _checkZipHeader(String path) {
  final file = File(path).openSync();
  try {
    final header = file.readSync(4);
    if (file.lengthSync() < 22 ||
        header.length != 4 ||
        header[0] != 80 ||
        header[1] != 75 ||
        !(header[2] == 3 && header[3] == 4 ||
            header[2] == 5 && header[3] == 6)) {
      throw const FormatException('文件不是有效的 JAR/ZIP。');
    }
  } finally {
    file.closeSync();
  }
}

Future<void> _checkModDirectory(GameInstance instance) async {
  if (await FileSystemEntity.type(instance.gameDirectory, followLinks: false) ==
      FileSystemEntityType.link) {
    throw const FormatException('游戏目录不能是符号链接。');
  }
  await ensurePackParents(
    instance.gameDirectory,
    p.join(instance.gameDirectory, 'mods', 'placeholder'),
  );
}

// Some shipped mods rely on Gson's lenient JSON (comments/raw line breaks).
dynamic _modJson(String source) {
  final output = StringBuffer();
  var quoted = false, escaped = false;
  for (var index = 0; index < source.length; index++) {
    final char = source[index];
    if (quoted) {
      if (escaped) {
        output.write(char);
        escaped = false;
        continue;
      }
      if (char == '\\') {
        output.write(char);
        escaped = true;
        continue;
      }
      if (char == '"') quoted = false;
      output.write(switch (char) {
        '\n' => r'\n',
        '\r' => r'\r',
        '\t' => r'\t',
        _ => char,
      });
    } else {
      if (char == '\uFEFF') continue;
      if (char == '"') quoted = true;
      if (char == '/' && index + 1 < source.length) {
        if (source[index + 1] == '/') {
          while (index < source.length && source[index] != '\n') {
            index++;
          }
          output.write('\n');
          continue;
        }
        if (source[index + 1] == '*') {
          index += 2;
          while (index + 1 < source.length &&
              !(source[index] == '*' && source[index + 1] == '/')) {
            index++;
          }
          index++;
          output.write(' ');
          continue;
        }
      }
      if (char == ',') {
        var next = index + 1;
        while (next < source.length && source[next].trim().isEmpty) {
          next++;
        }
        if (next < source.length &&
            (source[next] == '}' || source[next] == ']')) {
          continue;
        }
      }
      output.write(char);
    }
  }
  return jsonDecode(output.toString());
}

class LocalMod {
  final String path, name, id, version, description, loader;
  final bool enabled;
  final Uint8List? icon;
  final String? warning;
  const LocalMod({
    required this.path,
    required this.name,
    this.id = '',
    this.version = '',
    this.description = '',
    this.loader = '',
    this.enabled = true,
    this.icon,
    this.warning,
  });
  bool matches(String query) =>
      '$name $id $version $description ${p.basename(path)}'
          .toLowerCase()
          .contains(query.trim().toLowerCase());
}

/// Reads only bounded metadata/icon entries. No classes or embedded JARs run.
LocalMod readLocalMod(String path) {
  final enabled = !path.toLowerCase().endsWith('.disabled');
  final fallback = p
      .basename(path)
      .replaceFirst(RegExp(r'\.jar(?:\.disabled)?$', caseSensitive: false), '');
  InputFileStream? input;
  try {
    if (File(path).lengthSync() > 512 * 1024 * 1024) {
      throw const FormatException('文件过大');
    }
    _checkZipHeader(path);
    input = InputFileStream(path);
    final archive = ZipDecoder().decodeStream(input);
    String? text(String name) {
      final file = archive.findFile(name);
      if (file == null ||
          !file.isFile ||
          file.isSymbolicLink ||
          file.size > 1024 * 1024) {
        return null;
      }
      return utf8.decode(file.content, allowMalformed: true);
    }

    String name = fallback,
        id = '',
        version = '',
        description = '',
        loader = '';
    String? iconPath;
    final fabric = text('fabric.mod.json');
    if (fabric != null) {
      final j = _modJson(fabric) as Json;
      id = '${j['id'] ?? ''}';
      name = '${j['name'] ?? id}';
      version = '${j['version'] ?? ''}';
      description = '${j['description'] ?? ''}';
      loader = 'Fabric';
      final icon = j['icon'];
      if (icon is String) iconPath = icon;
      if (icon is Map && icon.isNotEmpty) {
        final keys = icon.keys.cast<String>().toList()
          ..sort(
            (a, b) => (int.tryParse(b) ?? 0).compareTo(int.tryParse(a) ?? 0),
          );
        iconPath = icon[keys.first] as String?;
      }
    } else {
      final neo = text('META-INF/neoforge.mods.toml');
      final forge = neo ?? text('META-INF/mods.toml');
      if (forge != null) {
        loader = neo == null ? 'Forge' : 'NeoForge';
        // Metadata strings from the first [[mods]] table, not dependency tables.
        final section = forge.split(
          RegExp(r'^\s*\[\[mods\]\]\s*$', multiLine: true),
        );
        final block = section.length > 1
            ? section[1].split(RegExp(r'^\s*\[', multiLine: true)).first
            : forge;
        String value(String key, [String source = '']) {
          source = source.isEmpty ? block : source;
          final match = RegExp(
            '^\\s*$key\\s*=\\s*("""|\'\'\'|"|\')([\\s\\S]*?)\\1',
            multiLine: true,
          ).firstMatch(source);
          return match?[2]?.trim().replaceAll(r'\n', '\n') ?? '';
        }

        id = value('modId');
        name = value('displayName');
        version = value('version');
        description = value('description');
        iconPath = value('logoFile');
        if (iconPath.isEmpty) iconPath = value('logoFile', forge);
        if (version.contains(r'${')) {
          version =
              RegExp(
                r'^Implementation-Version:\s*(.+)$',
                multiLine: true,
              ).firstMatch(text('META-INF/MANIFEST.MF') ?? '')?[1]?.trim() ??
              '';
        }
      } else {
        final legacy = text('mcmod.info');
        if (legacy != null) {
          final j = _modJson(legacy);
          final rows = j is List ? j : (j as Json)['modList'] as List? ?? [];
          if (rows.isNotEmpty) {
            final row = rows.first as Json;
            id = '${row['modid'] ?? ''}';
            name = '${row['name'] ?? fallback}';
            version = '${row['version'] ?? ''}';
            description = '${row['description'] ?? ''}';
            iconPath = row['logoFile'] as String?;
            loader = 'Forge';
          }
        }
      }
    }
    Uint8List? icon;
    if (iconPath != null &&
        !iconPath.contains('..') &&
        !p.posix.isAbsolute(iconPath)) {
      final entry = archive.findFile(iconPath);
      if (entry != null &&
          entry.isFile &&
          !entry.isSymbolicLink &&
          entry.size <= 512 * 1024) {
        icon = Uint8List.fromList(entry.content);
      }
    }
    return LocalMod(
      path: path,
      name: name.isEmpty ? fallback : name,
      id: id,
      version: version,
      description: description,
      loader: loader,
      enabled: enabled,
      icon: icon,
    );
  } catch (_) {
    return LocalMod(
      path: path,
      name: fallback,
      enabled: enabled,
      warning: '无法读取模组信息',
    );
  } finally {
    input?.close();
  }
}

Future<List<LocalMod>> scanLocalMods(
  GameInstance instance,
  CancellationToken token,
) async {
  final directory = Directory(p.join(instance.gameDirectory, 'mods'));
  if (!await directory.exists()) return [];
  final result = <LocalMod>[];
  await for (final entry in directory.list(followLinks: false)) {
    token.check();
    if (entry is File &&
        RegExp(
          r'\.jar(?:\.disabled)?$',
          caseSensitive: false,
        ).hasMatch(entry.path)) {
      result.add(readLocalMod(entry.path));
      // Yield between files to keep scrolling/cancellation responsive.
      await Future<void>.delayed(Duration.zero);
    }
  }
  result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return result;
}

Future<void> setModsEnabled(
  GameInstance instance,
  List<LocalMod> mods,
  bool enabled,
) async {
  await _checkModDirectory(instance);
  final root = p.join(instance.gameDirectory, 'mods');
  final changes = <(String, String)>[];
  for (final mod in mods.where((m) => m.enabled != enabled)) {
    if (!p.equals(p.dirname(mod.path), root) ||
        await FileSystemEntity.type(mod.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FormatException('模组文件位置已变化，请刷新列表。');
    }
    final target = enabled
        ? mod.path.substring(0, mod.path.length - '.disabled'.length)
        : '${mod.path}.disabled';
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('目标文件已存在：${p.basename(target)}');
    }
    changes.add((mod.path, target));
  }
  final done = <(String, String)>[];
  try {
    for (final change in changes) {
      await File(change.$1).rename(change.$2);
      done.add(change);
    }
  } catch (_) {
    for (final change in done.reversed) {
      await File(change.$2).rename(change.$1);
    }
    rethrow;
  }
}

Future<String> trashLocalMods(
  GameInstance instance,
  List<LocalMod> mods,
) async {
  await _checkModDirectory(instance);
  final root = p.join(instance.gameDirectory, 'mods');
  final destination = p.join(
    instance.launcherDirectory,
    'mod-trash',
    '${DateTime.now().microsecondsSinceEpoch}',
  );
  for (final mod in mods) {
    if (!p.equals(p.dirname(mod.path), root) ||
        await FileSystemEntity.type(mod.path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FormatException('模组文件位置已变化，请刷新列表。');
    }
  }
  await ensurePackParents(
    instance.gameDirectory,
    p.join(destination, 'placeholder'),
  );
  final moved = <(String, String)>[];
  try {
    for (final mod in mods) {
      final target = p.join(destination, p.basename(mod.path));
      await File(mod.path).rename(target);
      moved.add((mod.path, target));
    }
  } catch (_) {
    for (final item in moved.reversed) {
      await File(item.$2).rename(item.$1);
    }
    rethrow;
  }
  return destination;
}

Future<void> importLocalMods(
  GameInstance instance,
  List<String> paths, {
  bool replace = false,
}) async {
  await _checkModDirectory(instance);
  final root = p.join(instance.gameDirectory, 'mods');
  final names = <String>{};
  for (final path in paths) {
    if (!path.toLowerCase().endsWith('.jar') ||
        !names.add(p.basename(path).toLowerCase())) {
      throw const FormatException('请选择名称不同的 JAR 文件。');
    }
    final target = safeJoin(root, p.basename(path));
    await ensurePackParents(instance.gameDirectory, target);
    if (!replace && await File(target).exists()) {
      throw StateError('已存在：${p.basename(path)}');
    }
    _checkZipHeader(path);
    final input = InputFileStream(path);
    try {
      ZipDecoder().decodeStream(input);
    } finally {
      input.close();
    }
  }
  await publishFiles(root, [
    for (final path in paths)
      if (!p.equals(
        p.normalize(path),
        p.normalize(safeJoin(root, p.basename(path))),
      ))
        (path, safeJoin(root, p.basename(path))),
  ], CancellationToken());
}
