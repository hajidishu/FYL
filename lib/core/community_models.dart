import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'network.dart';
import 'download_rate.dart';

enum ContentSource { modrinth, curseforge }

extension ContentSourceName on ContentSource {
  String get label =>
      this == ContentSource.modrinth ? 'Modrinth' : 'CurseForge';
}

enum ContentKind { mod, modpack, datapack, resourcepack, shader }

extension ContentKindDetails on ContentKind {
  String get label => switch (this) {
    ContentKind.mod => 'Mod',
    ContentKind.modpack => '整合包',
    ContentKind.datapack => '数据包',
    ContentKind.resourcepack => '资源包',
    ContentKind.shader => '光影包',
  };
  bool get isResource => this != ContentKind.mod && this != ContentKind.modpack;
  bool get hasTarget => this != ContentKind.modpack;
  String get modrinthType => name;
  int get curseClassId => switch (this) {
    ContentKind.mod => 6,
    ContentKind.modpack => 4471,
    ContentKind.datapack => 6945,
    ContentKind.resourcepack => 12,
    ContentKind.shader => 6552,
  };
}

class ContentProject {
  final bool clientSupported;
  final ContentSource source;
  final ContentKind kind;
  final String id, slug, name, summary, author, website;
  final String? icon;
  final int downloads;
  final DateTime? updated;
  final List<String> gameVersions, loaders, categories;
  const ContentProject({
    required this.source,
    required this.kind,
    required this.id,
    required this.slug,
    required this.name,
    required this.summary,
    required this.author,
    required this.website,
    this.icon,
    this.downloads = 0,
    this.updated,
    this.gameVersions = const [],
    this.loaders = const [],
    this.categories = const [],
    this.clientSupported = true,
  });
}

class ContentFile {
  final String id, projectId, name, website;
  final List<String> urls;
  final Map<String, String> hashes;
  final int? size;
  const ContentFile({
    required this.name,
    this.id = '',
    this.projectId = '',
    this.website = '',
    this.urls = const [],
    this.hashes = const {},
    this.size,
  });
  DownloadFile download(String path) {
    if (urls.isEmpty) throw StateError('$name 需要从项目页面手动下载。');
    return DownloadFile(
      urls.first,
      path,
      size: size,
      hashes: hashes,
      alternativeUrls: urls.skip(1).toList(),
      requireIntegrity: true,
    );
  }

  Future<bool> matches(File file) async {
    return DownloadFile(
      '',
      file.path,
      size: size,
      hashes: hashes,
      requireIntegrity: true,
    ).matches(file);
  }

  ContentFile withWebsite(String value) => ContentFile(
    name: name,
    id: id,
    projectId: projectId,
    website: value,
    urls: urls,
    hashes: hashes,
    size: size,
  );
}

class ContentDependency {
  final String projectId;
  final String? versionId;
  final bool required;
  const ContentDependency(
    this.projectId, {
    this.versionId,
    this.required = true,
  });
}

class ContentVersion {
  final ContentSource source;
  final String id, projectId, name, number, releaseType;
  final DateTime published;
  final List<String> gameVersions, loaders;
  final List<ContentFile> files;
  final List<ContentDependency> dependencies;
  const ContentVersion({
    required this.source,
    required this.id,
    required this.projectId,
    required this.name,
    required this.number,
    required this.published,
    this.releaseType = 'release',
    this.gameVersions = const [],
    this.loaders = const [],
    this.files = const [],
    this.dependencies = const [],
  });
  bool supports(String minecraft, String? loader) =>
      (minecraft.isEmpty || gameVersions.contains(minecraft)) &&
      (loader == null || loader.isEmpty || loaders.contains(loader));
}

class ContentSearchResult {
  final List<ContentProject> projects;
  final bool hasMore;
  final bool failed;
  final List<String> notices;
  const ContentSearchResult(
    this.projects, {
    this.hasMore = false,
    this.failed = false,
    this.notices = const [],
  });
}

class ContentVersionPage {
  final List<ContentVersion> versions;
  final bool hasMore;
  const ContentVersionPage(this.versions, {this.hasMore = false});
}

String? instanceModLoader(GameInstance instance) {
  final value = instance.components.toLowerCase();
  for (final loader in ['neoforge', 'forge', 'fabric', 'quilt']) {
    if (RegExp('(^|[^a-z])$loader([^a-z]|\$)').hasMatch(value)) return loader;
  }
  return null;
}

String contentFileName(String value) {
  final name = p.posix.basename(value.replaceAll('\\', '/'));
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name)) {
    throw const FormatException('下载文件名无效。');
  }
  return name;
}

enum ContentTaskState { running, waiting, completed, cancelled, failed }

class ContentTask {
  final String id, title;
  final ContentKind kind;
  final ContentSource source;
  ContentTaskState state = ContentTaskState.running;
  String stage = '准备下载', detail = '';
  String? error, destination;
  // Unregistered, isolated installation prepared for a pack upgrade.
  GameInstance? preparedInstance;
  String? updateTargetId, updateArchive;
  ContentProject? updateProject;
  ContentVersion? updateRelease;
  bool canRetry = true;
  int done = 0, total = 0, cachedBytes = 0;
  int _bytes = 0;
  final downloadRate = DownloadRate();
  int get bytes => _bytes;
  set bytes(int value) {
    final delta = value - _bytes;
    _bytes = value;
    if (delta < 0) {
      downloadRate.reset();
    } else {
      downloadRate.add(delta);
    }
  }

  List<ContentFile> missing = [];
  CancellationToken token = CancellationToken();
  ContentTask(this.title, this.kind, this.source)
    : id = DateTime.now().microsecondsSinceEpoch.toString();
  double? get progress => total == 0 ? null : done / total;
}
