import 'dart:io';

import 'package:path/path.dart' as p;

import 'community_models.dart';
import 'models.dart';
import 'pack_import.dart' show ensurePackParents;

/// Only preview metadata is persisted. Resuming a prepared upgrade does not
/// require catalog access, a new download, or the original installer session.
Json preparedPackUpdateJson(ContentTask task) {
  final project = task.updateProject!, release = task.updateRelease!;
  return {
    'id': task.id,
    'title': task.title,
    'instance': task.preparedInstance!.toJson(),
    'targetId': task.updateTargetId,
    'archive': task.updateArchive,
    'bytes': task.bytes,
    'cachedBytes': task.cachedBytes,
    'project': {
      'source': project.source.name,
      'id': project.id,
      'slug': project.slug,
      'name': project.name,
      'website': project.website,
    },
    'release': {
      'id': release.id,
      'projectId': release.projectId,
      'name': release.name,
      'number': release.number,
      'published': release.published.toIso8601String(),
      'releaseType': release.releaseType,
      'gameVersions': release.gameVersions,
      'loaders': release.loaders,
    },
  };
}

ContentTask preparedPackUpdateFromJson(Json json) {
  final project = json['project'] as Json, release = json['release'] as Json;
  final source = ContentSource.values.byName(project['source'] as String);
  final id = json['id'] as String;
  if (!RegExp(r'^\d+$').hasMatch(id)) {
    throw const FormatException('整合包升级暂存目录无效。');
  }
  final staged = GameInstance.fromJson(json['instance'] as Json);
  return ContentTask(
      json['title'] as String,
      ContentKind.modpack,
      source,
      id: id,
    )
    ..preparedInstance = staged
    ..updateTargetId = json['targetId'] as String
    ..updateArchive = json['archive'] as String
    ..bytes = json['bytes'] as int? ?? 0
    ..cachedBytes = json['cachedBytes'] as int? ?? 0
    ..updateProject = ContentProject(
      source: source,
      kind: ContentKind.modpack,
      id: project['id'] as String,
      slug: project['slug'] as String,
      name: project['name'] as String,
      website: project['website'] as String,
      summary: '',
      author: '',
    )
    ..updateRelease = ContentVersion(
      source: source,
      id: release['id'] as String,
      projectId: release['projectId'] as String,
      name: release['name'] as String,
      number: release['number'] as String,
      published: DateTime.parse(release['published'] as String),
      releaseType: release['releaseType'] as String,
      gameVersions: (release['gameVersions'] as List).cast<String>(),
      loaders: (release['loaders'] as List).cast<String>(),
    )
    ..state = ContentTaskState.completed
    ..stage = '等待确认升级'
    ..destination = staged.gameDirectory;
}

void validatePreparedPackUpdateLocation(
  ContentTask task,
  List<GameInstance> instances,
  String supportDirectory,
) {
  final staged = task.preparedInstance!;
  final target = instances
      .where((instance) => instance.id == task.updateTargetId)
      .firstOrNull;
  final archive = task.updateArchive!;
  if (target == null ||
      !p.equals(staged.root, target.root) ||
      !staged.isolated ||
      !staged.name.startsWith('FYL-update-') ||
      validateVersionName(staged.name) != null ||
      instances.any(
        (instance) =>
            instance.id == staged.id ||
            p.equals(instance.versionDirectory, staged.versionDirectory),
      ) ||
      !p.isWithin(supportDirectory, archive)) {
    throw const FormatException('整合包升级暂存目录无效。');
  }
}

Future<void> validatePreparedPackUpdate(
  ContentTask task,
  List<GameInstance> instances,
  String supportDirectory,
) async {
  validatePreparedPackUpdateLocation(task, instances, supportDirectory);
  final staged = task.preparedInstance!, archive = task.updateArchive!;
  await ensurePackParents(
    staged.root,
    p.join(staged.launcherDirectory, 'modpack.json'),
    createParents: false,
  );
  await ensurePackParents(supportDirectory, archive, createParents: false);
  if (!await Directory(staged.versionDirectory).exists() ||
      await FileSystemEntity.type(archive, followLinks: false) !=
          FileSystemEntityType.file ||
      await FileSystemEntity.type(
            p.join(staged.launcherDirectory, 'modpack.json'),
            followLinks: false,
          ) !=
          FileSystemEntityType.file) {
    throw const FormatException('此版本没有整合包来源记录。');
  }
}
