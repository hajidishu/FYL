import 'dart:convert';
import 'community_models.dart';
import 'models.dart';
import 'network.dart';

class CommunityCatalog {
  final LauncherSettings settings;
  final OfficialNetwork network;
  final String modrinthBase, curseforgeBase;
  CommunityCatalog(
    this.settings, {
    OfficialNetwork? network,
    this.modrinthBase = 'https://api.modrinth.com/v2',
    this.curseforgeBase = 'https://api.curseforge.com/v1',
  }) : network =
           network ??
           OfficialNetwork(
             settings,
             community: true,
             hostHeaders: {
               'api.curseforge.com': {'x-api-key': settings.curseforgeApiKey},
             },
           );
  void close() => network.close();
  void _requireCurseForge() {
    if (settings.curseforgeApiKey.trim().isEmpty) {
      throw StateError('请先在设置的“社区资源”中配置 CurseForge API Key。');
    }
  }

  Uri _url(String base, String path, [Map<String, String> query = const {}]) =>
      Uri.parse(
        '$base$path',
      ).replace(queryParameters: query.isEmpty ? null : query);
  Future<dynamic> _get(
    ContentSource source,
    String path,
    CancellationToken token, [
    Map<String, String> query = const {},
  ]) async {
    if (source == ContentSource.curseforge) _requireCurseForge();
    return network.jsonValue(
      _url(
        source == ContentSource.modrinth ? modrinthBase : curseforgeBase,
        path,
        query,
      ).toString(),
      token: token,
    );
  }

  Future<ContentSearchResult> search({
    required ContentKind kind,
    String query = '',
    String minecraft = '',
    String? loader,
    ContentSource? source,
    int page = 0,
    bool newest = false,
    CancellationToken? token,
  }) async {
    final cancellation = token ?? CancellationToken();
    final sources = source == null ? ContentSource.values : [source];
    final projects = <ContentProject>[];
    final notices = <String>[];
    var hasMore = false;
    final results = await Future.wait(
      sources.map((provider) async {
        try {
          if (provider == ContentSource.modrinth) {
            final facets = <List<String>>[
              ['project_type:${kind.modrinthType}'],
              if (minecraft.isNotEmpty) ['versions:$minecraft'],
              if (loader != null && loader.isNotEmpty) ['categories:$loader'],
            ];
            final json =
                await _get(provider, '/search', cancellation, {
                      'query': query,
                      'facets': jsonEncode(facets),
                      'limit': '20',
                      'offset': '${page * 20}',
                      'index': newest ? 'updated' : 'downloads',
                    })
                    as Json;
            final hits = (json['hits'] as List).cast<Json>();
            return ContentSearchResult(
              hits.map((hit) => _modrinthProject(hit, kind)).toList(),
              hasMore:
                  page * 20 + hits.length < (json['total_hits'] as num).toInt(),
            );
          }
          final json =
              await _get(provider, '/mods/search', cancellation, {
                    'gameId': '432',
                    'classId': '${kind.curseClassId}',
                    'searchFilter': query,
                    'pageSize': '20',
                    'index': '${page * 20}',
                    'sortField': newest ? '3' : '6',
                    'sortOrder': 'desc',
                    if (minecraft.isNotEmpty) 'gameVersion': minecraft,
                    if (_loaderId(loader) != null)
                      'modLoaderType': '${_loaderId(loader)}',
                  })
                  as Json;
          final rows = (json['data'] as List).cast<Json>();
          final total =
              (json['pagination']?['totalCount'] as num?)?.toInt() ??
              rows.length;
          return ContentSearchResult(
            rows.map((row) => _curseProject(row, kind)).toList(),
            hasMore: page * 20 + rows.length < total,
          );
        } catch (e) {
          cancellation.check();
          return ContentSearchResult(
            [],
            failed: true,
            notices: ['${provider.label}：${_cleanError(e)}'],
          );
        }
      }),
    );
    for (final result in results) {
      projects.addAll(result.projects);
      notices.addAll(result.notices);
      hasMore |= result.hasMore;
    }
    projects.sort(
      (a, b) => newest
          ? (b.updated ?? DateTime(1970)).compareTo(a.updated ?? DateTime(1970))
          : b.downloads.compareTo(a.downloads),
    );
    return ContentSearchResult(
      projects,
      hasMore: hasMore,
      failed: results.isNotEmpty && results.every((result) => result.failed),
      notices: notices,
    );
  }

  Future<ContentProject> project(
    ContentSource source,
    String id,
    ContentKind kind,
    CancellationToken token,
  ) async {
    final json = await _get(
      source,
      source == ContentSource.modrinth ? '/project/$id' : '/mods/$id',
      token,
    );
    return source == ContentSource.modrinth
        ? _modrinthProject(json as Json, kind)
        : _curseProject(json['data'] as Json, kind);
  }

  Future<String> description(
    ContentProject project,
    CancellationToken token,
  ) async {
    if (project.source == ContentSource.modrinth) {
      final json =
          await _get(project.source, '/project/${project.id}', token) as Json;
      return (json['body'] as String?) ?? project.summary;
    }
    final json =
        await _get(project.source, '/mods/${project.id}/description', token)
            as Json;
    return (json['data'] as String? ?? project.summary)
        .replaceAll(
          RegExp(r'<(?:br\s*/?|/p|/div|/li|/h[1-6])>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  Future<String> versionNotes(
    ContentVersion version,
    CancellationToken token,
  ) async {
    final data = await _get(
      version.source,
      version.source == ContentSource.modrinth
          ? '/version/${version.id}'
          : '/mods/${version.projectId}/files/${version.id}/changelog',
      token,
    );
    final value = version.source == ContentSource.modrinth
        ? (data as Json)['changelog']
        : (data as Json)['data'];
    return (value as String? ?? '')
        .replaceAll(
          RegExp(r'<(?:br\s*/?|/p|/div|/li|/h[1-6])>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }

  Future<ContentVersionPage> versions(
    ContentProject project,
    CancellationToken token, {
    String minecraft = '',
    String? loader,
    int page = 0,
  }) async {
    if (project.kind == ContentKind.datapack &&
        project.source == ContentSource.modrinth) {
      loader = 'datapack';
    }
    if (project.source == ContentSource.modrinth) {
      final data =
          await _get(project.source, '/project/${project.id}/version', token, {
                if (minecraft.isNotEmpty)
                  'game_versions': jsonEncode([minecraft]),
                if (loader != null && loader.isNotEmpty)
                  'loaders': jsonEncode([loader]),
              })
              as List;
      final result = data
          .cast<Json>()
          .map((j) => _modrinthVersion(j, project.website))
          .toList();
      result.sort((a, b) => b.published.compareTo(a.published));
      return ContentVersionPage(result);
    }
    final data =
        await _get(project.source, '/mods/${project.id}/files', token, {
              'pageSize': '50',
              'index': '${page * 50}',
              if (minecraft.isNotEmpty) 'gameVersion': minecraft,
              if (_loaderId(loader) != null)
                'modLoaderType': '${_loaderId(loader)}',
            })
            as Json;
    final rows = (data['data'] as List).cast<Json>();
    final result = rows
        .where((j) => j['isServerPack'] != true)
        .map((j) => _curseVersion(j, project.website))
        .toList();
    result.sort((a, b) => b.published.compareTo(a.published));
    return ContentVersionPage(
      result,
      hasMore:
          page * 50 + rows.length <
          ((data['pagination']?['totalCount'] as num?)?.toInt() ?? rows.length),
    );
  }

  Future<ContentVersion> version(
    ContentSource source,
    String projectId,
    String versionId,
    CancellationToken token,
  ) async {
    final json =
        await _get(
              source,
              source == ContentSource.modrinth
                  ? '/version/$versionId'
                  : '/mods/$projectId/files/$versionId',
              token,
            )
            as Json;
    final value = source == ContentSource.modrinth
        ? _modrinthVersion(json, 'https://modrinth.com/mod/$projectId')
        : _curseVersion(json['data'] as Json, '');
    if (source == ContentSource.modrinth &&
        projectId.isNotEmpty &&
        value.projectId != projectId) {
      throw const FormatException('项目与文件版本不匹配。');
    }
    return value;
  }

  Future<ContentFile> curseFile(
    String projectId,
    String fileId,
    CancellationToken token,
  ) async {
    final value = await version(
      ContentSource.curseforge,
      projectId,
      fileId,
      token,
    );
    var file = value.files.single;
    if (file.urls.isEmpty) {
      final info = await project(
        ContentSource.curseforge,
        projectId,
        ContentKind.mod,
        token,
      );
      file = file.withWebsite('${info.website}/files/$fileId');
    }
    return file;
  }

  Future<Map<String, ContentVersion>> versionsFromHashes(
    List<String> hashes,
    CancellationToken token, {
    String? minecraft,
    String? loader,
    List<String>? channels,
  }) async {
    final update = minecraft != null && loader != null;
    final data = await network.postJson(
      '$_modrinthVersionFiles${update ? '/update' : ''}',
      {
        'hashes': hashes,
        'algorithm': 'sha1',
        if (update) 'game_versions': [minecraft],
        if (update) 'loaders': [loader],
        'version_types': ?channels,
      },
      token,
    );
    return {
      for (final entry in data.entries)
        entry.key: _modrinthVersion(
          entry.value as Json,
          'https://modrinth.com/mod/${entry.value['project_id']}',
        ),
    };
  }

  String get _modrinthVersionFiles => '$modrinthBase/version_files';

  Future<List<ContentVersion>> fingerprintMatches(
    List<int> fingerprints,
    CancellationToken token,
  ) async {
    _requireCurseForge();
    final data = await network.postJson('$curseforgeBase/fingerprints/432', {
      'fingerprints': fingerprints,
    }, token);
    return [
      for (final match in data['data']['exactMatches'] as List? ?? [])
        _curseVersion(match['file'] as Json, ''),
    ];
  }

  Future<List<ContentFile>> modFiles(
    ContentProject project,
    ContentVersion release,
    GameInstance target,
    CancellationToken token, {
    bool dependencies = true,
  }) async {
    final loader = instanceModLoader(target);
    if (!project.clientSupported) {
      throw StateError('该模组仅适用于服务端。');
    }
    if (loader == null) throw StateError('请选择已安装模组加载器的游戏版本。');
    if (!release.supports(target.version, loader)) {
      throw StateError('此版本不支持目标游戏或加载器。');
    }
    final files = <ContentFile>[];
    final visited = <String>{};
    Future<void> visit(ContentVersion current) async {
      token.check();
      final identity =
          '${current.source.name}:${current.projectId}:${current.id}';
      if (!visited.add(identity)) return;
      if (visited.length > 100) throw const FormatException('模组依赖数量超过限制。');
      final jars = current.files
          .where((f) => f.name.toLowerCase().endsWith('.jar'))
          .toList();
      if (jars.isEmpty) throw StateError('${current.name} 没有可安装的 JAR 文件。');
      files.add(jars.first);
      if (!dependencies) return;
      for (final dependency in current.dependencies.where((d) => d.required)) {
        ContentVersion next;
        if (dependency.versionId != null) {
          next = await version(
            current.source,
            dependency.projectId,
            dependency.versionId!,
            token,
          );
        } else {
          final info = await this.project(
            current.source,
            dependency.projectId,
            ContentKind.mod,
            token,
          );
          final page = await versions(
            info,
            token,
            minecraft: target.version,
            loader: loader,
          );
          final compatible = page.versions
              .where((v) => v.supports(target.version, loader))
              .toList();
          if (compatible.isEmpty) throw StateError('找不到 ${info.name} 的兼容依赖版本。');
          next = compatible.firstWhere(
            (v) => v.releaseType == 'release',
            orElse: () => compatible.first,
          );
        }
        if (!next.supports(target.version, loader)) {
          throw StateError('依赖 ${next.name} 与目标版本不兼容。');
        }
        await visit(next);
      }
    }

    await visit(release);
    final names = <String, ContentFile>{};
    for (final file in files) {
      final name = contentFileName(file.name).toLowerCase();
      if (names.containsKey(name) && names[name]!.id != file.id) {
        throw StateError('依赖文件名冲突：${file.name}');
      }
      names[name] = file;
    }
    return names.values.toList();
  }

  int? _loaderId(String? value) => switch (value) {
    'forge' => 1,
    'fabric' => 4,
    'quilt' => 5,
    'neoforge' => 6,
    _ => null,
  };
  String _cleanError(Object error) => error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceAll(
        settings.curseforgeApiKey.isEmpty
            ? '\u0000'
            : settings.curseforgeApiKey,
        '[已隐藏密钥]',
      );
  List<String> _strings(dynamic value) =>
      (value as List? ?? []).map((v) => '$v').toList();
  ContentProject _modrinthProject(Json j, ContentKind kind) => ContentProject(
    source: ContentSource.modrinth,
    clientSupported: j['client_side'] != 'unsupported',
    kind: kind,
    id: '${j['project_id'] ?? j['id']}',
    slug: j['slug'] as String? ?? '',
    name: j['title'] as String,
    summary: j['description'] as String? ?? '',
    author: j['author'] as String? ?? '',
    website: 'https://modrinth.com/${kind.name}/${j['slug'] ?? j['id']}',
    icon: j['icon_url'] as String?,
    downloads: (j['downloads'] as num?)?.toInt() ?? 0,
    updated: DateTime.tryParse('${j['date_modified'] ?? j['updated']}'),
    gameVersions: _strings(j['versions'] ?? j['game_versions']),
    loaders: _strings(j['loaders'] ?? j['categories'])
        .where(
          (s) => [
            'fabric',
            'forge',
            'neoforge',
            'quilt',
            'iris',
            'optifine',
          ].contains(s),
        )
        .toList(),
    categories: _strings(j['display_categories'] ?? j['categories']),
  );
  ContentProject _curseProject(Json j, ContentKind kind) => ContentProject(
    source: ContentSource.curseforge,
    kind: kind,
    id: '${j['id']}',
    slug: j['slug'] as String? ?? '',
    name: j['name'] as String,
    summary: j['summary'] as String? ?? '',
    author: (j['authors'] as List? ?? []).map((a) => a['name']).join(', '),
    website:
        j['links']?['websiteUrl'] as String? ?? 'https://www.curseforge.com',
    icon: (j['logo']?['url'] ?? j['logo']?['thumbnailUrl']) as String?,
    downloads: (j['downloadCount'] as num?)?.toInt() ?? 0,
    updated: DateTime.tryParse('${j['dateModified']}'),
    gameVersions: (j['latestFilesIndexes'] as List? ?? [])
        .map((v) => '${v['gameVersion']}')
        .toSet()
        .toList(),
    loaders: (j['latestFilesIndexes'] as List? ?? [])
        .map(
          (v) => switch (v['modLoader']) {
            1 => 'forge',
            4 => 'fabric',
            6 => 'neoforge',
            5 => 'quilt',
            _ => '',
          },
        )
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList(),
    categories: (j['categories'] as List? ?? [])
        .map((v) => '${v['name']}')
        .toList(),
  );
  ContentVersion _modrinthVersion(Json j, String website) {
    final raw = (j['files'] as List).cast<Json>().toList()
      ..sort(
        (a, b) =>
            (b['primary'] == true ? 1 : 0) - (a['primary'] == true ? 1 : 0),
      );
    return ContentVersion(
      source: ContentSource.modrinth,
      id: j['id'] as String,
      projectId: j['project_id'] as String,
      name: j['name'] as String,
      number: j['version_number'] as String,
      published: DateTime.parse(j['date_published'] as String),
      releaseType: j['version_type'] as String? ?? 'release',
      gameVersions: _strings(j['game_versions']),
      loaders: _strings(j['loaders']),
      files: raw
          .map(
            (f) => ContentFile(
              name: contentFileName(f['filename'] as String),
              id: j['id'] as String,
              projectId: j['project_id'] as String,
              website: '$website/version/${j['id']}',
              urls: [f['url'] as String],
              hashes: Map<String, String>.from(f['hashes'] as Map),
              size: (f['size'] as num?)?.toInt(),
            ),
          )
          .toList(),
      dependencies: (j['dependencies'] as List? ?? [])
          .where((d) => d['dependency_type'] == 'required')
          .map(
            (d) => ContentDependency(
              d['project_id'] as String? ?? '',
              versionId: d['version_id'] as String?,
            ),
          )
          .toList(),
    );
  }

  ContentVersion _curseVersion(Json j, String website) {
    final hashes = <String, String>{};
    for (final h in j['hashes'] as List? ?? []) {
      if (h['algo'] == 1 || h['algo'] == 2) {
        hashes[h['algo'] == 1 ? 'sha1' : 'md5'] = h['value'] as String;
      }
    }
    final games = _strings(j['gameVersions']);
    final url = j['downloadUrl'] as String?;
    return ContentVersion(
      source: ContentSource.curseforge,
      id: '${j['id']}',
      projectId: '${j['modId']}',
      name: j['displayName'] as String,
      number: j['displayName'] as String,
      published: DateTime.parse(j['fileDate'] as String),
      releaseType: switch (j['releaseType']) {
        2 => 'beta',
        3 => 'alpha',
        _ => 'release',
      },
      gameVersions: games
          .where((v) => RegExp(r'^\d+\.\d+').hasMatch(v))
          .toList(),
      loaders: games
          .map((v) => v.toLowerCase())
          .where(
            (v) => [
              'forge',
              'neoforge',
              'fabric',
              'quilt',
              'iris',
              'optifine',
            ].contains(v),
          )
          .toList(),
      files: [
        ContentFile(
          name: contentFileName(j['fileName'] as String),
          id: '${j['id']}',
          projectId: '${j['modId']}',
          website: website.isEmpty ? '' : '$website/files/${j['id']}',
          urls: url == null || url.isEmpty ? [] : [url],
          hashes: hashes,
          size: (j['fileLength'] as num?)?.toInt(),
        ),
      ],
      dependencies: (j['dependencies'] as List? ?? [])
          .where((d) => d['relationType'] == 3)
          .map((d) => ContentDependency('${d['modId']}'))
          .toList(),
    );
  }
}
