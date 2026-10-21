import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'community_models.dart';
import 'pack_import.dart';

Future<(PackPlan, ContentProject, ContentVersion)> stageLocalPack(
  String path,
  String supportDirectory,
) => Isolate.run(() async {
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException('请选择普通的整合包文件。');
  }
  await inspectModpack(path);
  final hash = (await sha256.bind(File(path).openRead()).first).toString();
  final cached = File(
    p.join(supportDirectory, 'cache', 'local-packs', hash, 'pack.zip'),
  );
  await ensurePackParents(supportDirectory, cached.path);
  final type = await FileSystemEntity.type(cached.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    throw const FormatException('整合包缓存位置无效。');
  }
  final reusable =
      type == FileSystemEntityType.file &&
      (await sha256.bind(cached.openRead()).first).toString() == hash;
  if (!reusable) {
    await cached.parent.create(recursive: true);
    final temporary = File(
      '${cached.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await File(path).copy(temporary.path);
      if ((await sha256.bind(temporary.openRead()).first).toString() != hash) {
        throw const FormatException('整合包文件在读取过程中发生了变化，请重试。');
      }
      if (await cached.exists()) await cached.delete();
      await temporary.rename(cached.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
  final plan = await inspectModpack(cached.path);
  final project = ContentProject(
    source: plan.source,
    kind: ContentKind.modpack,
    id: 'local-$hash',
    slug: '',
    name: plan.name,
    summary: '',
    author: '',
    website: '',
  );
  final release = ContentVersion(
    source: plan.source,
    id: hash,
    projectId: project.id,
    name: plan.version,
    number: plan.version,
    published: DateTime.now(),
    gameVersions: [plan.minecraft],
  );
  return (plan, project, release);
});
