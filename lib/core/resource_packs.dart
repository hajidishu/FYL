import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'community_models.dart';
import 'models.dart';

Future<List<Directory>> dataPackWorlds(GameInstance instance) async {
  final saves = p.join(instance.gameDirectory, 'saves');
  if (await FileSystemEntity.type(saves, followLinks: false) !=
      FileSystemEntityType.directory) {
    return [];
  }
  final worlds = <Directory>[];
  await for (final entry in Directory(saves).list(followLinks: false)) {
    if (entry is Directory &&
        await FileSystemEntity.type(
              p.join(entry.path, 'level.dat'),
              followLinks: false,
            ) ==
            FileSystemEntityType.file) {
      worlds.add(entry);
    }
  }
  worlds.sort(
    (a, b) => p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase()),
  );
  return worlds;
}

String resourceDirectory(
  GameInstance instance,
  ContentKind kind, {
  String? world,
}) => switch (kind) {
  ContentKind.resourcepack => p.join(instance.gameDirectory, 'resourcepacks'),
  ContentKind.shader => p.join(instance.gameDirectory, 'shaderpacks'),
  ContentKind.datapack when world != null => p.join(world, 'datapacks'),
  _ => throw ArgumentError('请选择资源类型及存档。'),
};

ContentFile resourceFile(
  ContentProject project,
  ContentVersion release,
  GameInstance target,
) {
  if (!project.kind.isResource ||
      release.projectId != project.id ||
      release.source != project.source) {
    throw const FormatException('资源类型或发布版本不匹配。');
  }
  if (release.gameVersions.isNotEmpty &&
      !release.supports(target.version, null)) {
    throw StateError('此${project.kind.label}不支持 Minecraft ${target.version}。');
  }
  return release.files
          .where((file) => file.name.toLowerCase().endsWith('.zip'))
          .firstOrNull ??
      (throw StateError('此版本没有可用的 ZIP 文件。'));
}

Future<void> validateResourceArchive(String path, ContentKind kind) =>
    Isolate.run(() {
      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        final valid = kind == ContentKind.shader
            ? archive.files.any(
                (file) => file.isFile && file.name.startsWith('shaders/'),
              )
            : archive.findFile('pack.mcmeta')?.isFile == true;
        if (!valid) throw FormatException('文件不是有效的${kind.label}，请检查压缩包结构。');
      } finally {
        input.closeSync();
      }
    });
