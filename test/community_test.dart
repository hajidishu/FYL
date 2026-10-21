import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/content_installer.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/pack_import.dart';
import 'package:path/path.dart' as p;

class FixtureNetwork extends OfficialNetwork {
  FixtureNetwork(super.settings)
    : super(
        allowLocalhost: true,
        community: true,
        hostHeaders: {
          '127.0.0.1': {'x-api-key': 'test-cf-key'},
        },
      );
  @override
  Future<Json> json(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async {
    if (url == versionManifestUrl) {
      return {
        'versions': [
          {
            'id': '1.21.1',
            'type': 'release',
            'url': 'https://piston-meta.mojang.com/test.json',
            'releaseTime': '2024-08-08T00:00:00Z',
          },
        ],
      };
    }
    return super.json(url, expectedHash: expectedHash, token: token);
  }

  @override
  Future<dynamic> jsonValue(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async {
    if (url.startsWith('https://meta.fabricmc.net/')) {
      return [
        {
          'loader': {
            'version': '0.99.0',
            'maven': 'net.fabricmc:fabric-loader:0.99.0',
            'stable': true,
          },
        },
        {
          'loader': {
            'version': '0.16.10',
            'maven': 'net.fabricmc:fabric-loader:0.16.10',
            'stable': true,
          },
        },
      ];
    }
    return super.jsonValue(url, expectedHash: expectedHash, token: token);
  }
}

void main() {
  late Directory directory;
  late HttpServer server;
  late String base;
  late LauncherSettings settings;
  late CommunityCatalog catalog;
  late ContentInstaller installer;
  final installed = <GameInstance>[];
  final requests = <String>[];
  final jar = utf8.encode('a verified mod file');
  List<int> packBytes = [];
  bool restricted = false;
  InstallTask? baseTask;
  Map<String, String> hashes(List<int> bytes) => {
    'sha1': sha1.convert(bytes).toString(),
    'sha512': sha512.convert(bytes).toString(),
  };
  Json versionJson(String projectId, {bool dependency = false}) => {
    'id': '$projectId-version',
    'project_id': projectId,
    'name': '$projectId release',
    'version_number': '1.0.0',
    'date_published': '2024-08-08T00:00:00Z',
    'version_type': 'release',
    'game_versions': ['1.21.1'],
    'loaders': ['fabric'],
    'files': [
      {
        'filename': '$projectId.jar',
        'primary': true,
        'url': '$base/artifact',
        'hashes': hashes(jar),
        'size': jar.length,
      },
    ],
    'dependencies': [
      if (dependency)
        {
          'project_id': 'dependency',
          'version_id': null,
          'dependency_type': 'required',
        },
    ],
  };
  Json curseVersion() => {
    'id': 900,
    'modId': 77,
    'displayName': 'CF release',
    'fileName': 'curse-mod.jar',
    'fileDate': '2024-08-08T00:00:00Z',
    'gameVersions': ['1.21.1', 'Fabric'],
    'releaseType': 1,
    'downloadUrl': restricted ? null : '$base/artifact',
    'fileLength': jar.length,
    'hashes': [
      {'value': sha1.convert(jar).toString(), 'algo': 1},
    ],
    'dependencies': [],
  };
  ContentProject project({
    ContentSource source = ContentSource.modrinth,
    ContentKind kind = ContentKind.mod,
  }) => ContentProject(
    source: source,
    kind: kind,
    id: source == ContentSource.modrinth ? 'demo' : '77',
    slug: 'demo',
    name: 'Demo',
    summary: 'Example project',
    author: 'Author',
    website: 'https://modrinth.com/mod/demo',
  );
  ContentVersion packRelease(ContentSource source) => ContentVersion(
    source: source,
    id: 'pack-1',
    projectId: 'demo',
    name: 'Pack Release',
    number: '1',
    published: DateTime(2024),
    files: [
      ContentFile(
        name: source == ContentSource.modrinth ? 'demo.mrpack' : 'demo.zip',
        urls: ['$base/pack'],
        hashes: hashes(packBytes),
        size: packBytes.length,
      ),
    ],
  );
  Future<String> writePack(
    Json manifest, {
    bool curse = false,
    Map<String, String> extra = const {},
  }) async {
    final zip = Archive()
      ..add(
        ArchiveFile.string(
          curse ? 'manifest.json' : 'modrinth.index.json',
          jsonEncode(manifest),
        ),
      );
    for (final entry in extra.entries) {
      zip.add(ArchiveFile.string(entry.key, entry.value));
    }
    packBytes = ZipEncoder().encode(zip);
    final path = p.join(directory.path, curse ? 'test.zip' : 'test.mrpack');
    await File(path).writeAsBytes(packBytes);
    return path;
  }

  Json mrManifest() => {
    'formatVersion': 1,
    'game': 'minecraft',
    'name': 'Example Pack',
    'versionId': '1.0',
    'dependencies': {'minecraft': '1.21.1', 'fabric-loader': '0.16.10'},
    'files': [
      {
        'path': 'mods/demo.jar',
        'hashes': hashes(jar),
        'downloads': ['$base/artifact'],
        'fileSize': jar.length,
      },
      {
        'path': 'mods/server.jar',
        'env': {'client': 'unsupported'},
      },
      {
        'path': 'mods/optional.jar',
        'hashes': hashes(jar),
        'downloads': ['$base/artifact'],
        'fileSize': jar.length,
        'env': {'client': 'optional'},
      },
    ],
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-content-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    settings = LauncherSettings(
      gameRoot: directory.path,
      downloadRetries: 0,
      curseforgeApiKey: 'test-cf-key',
    );
    restricted = false;
    installed.clear();
    requests.clear();
    baseTask = null;
    CommunityCatalog create(LauncherSettings value) => CommunityCatalog(
      value,
      network: FixtureNetwork(value),
      modrinthBase: '$base/mr',
      curseforgeBase: '$base/cf',
    );
    catalog = create(settings);
    installer = ContentInstaller(
      platform: const HostPlatform('windows', 'x86_64'),
      supportDirectory: directory.path,
      settings: settings.copy,
      catalogFactory: create,
      onChanged: () {},
      busy: () =>
          installer.tasks.any((t) => t.state == ContentTaskState.running),
      onInstalled: (instance) async => installed.add(instance),
      installBase: (task, token, update) async {
        baseTask = task;
        return GameInstance(
          id: 'installed-pack',
          name: task.instanceName,
          version: task.version.id,
          root: directory.path,
          isolated: task.settings.isolateVersions,
          javaMajor: 21,
          components: task.options.summary,
        );
      },
    );
    server.listen((request) async {
      final path = request.uri.path;
      requests.add(path);
      Object? data;
      if (path.startsWith('/cf/')) {
        expect(request.headers.value('x-api-key'), 'test-cf-key');
      }
      if (path == '/artifact' || path == '/pack') {
        request.response.add(path == '/artifact' ? jar : packBytes);
      } else {
        request.response.headers.contentType = ContentType.json;
        if (path == '/mr/search') {
          expect(
            (jsonDecode(request.uri.queryParameters['facets']!) as List).expand(
              (v) => v as List,
            ),
            contains('versions:1.21.1'),
          );
          data = {
            'hits': [
              {
                'project_id': 'demo',
                'slug': 'demo',
                'title': 'Demo',
                'description': 'Summary',
                'author': 'Author',
                'downloads': 12,
                'versions': ['1.21.1'],
                'categories': ['fabric'],
              },
            ],
            'total_hits': 21,
          };
        } else if (path == '/cf/mods/search') {
          expect(request.uri.queryParameters['gameVersion'], '1.21.1');
          data = {
            'data': [
              {
                'id': 77,
                'slug': 'cf-demo',
                'name': 'CF Demo',
                'summary': 'CF Summary',
                'links': {
                  'websiteUrl':
                      'https://www.curseforge.com/minecraft/mc-mods/cf-demo',
                },
                'authors': [],
                'downloadCount': 10,
              },
            ],
            'pagination': {'totalCount': 1},
          };
        } else if (path == '/mr/project/demo/version') {
          data = [versionJson('demo', dependency: true)];
        } else if (path == '/mr/project/dependency/version') {
          data = [versionJson('dependency')];
        } else if (path == '/mr/project/dependency') {
          data = {
            'id': 'dependency',
            'slug': 'dependency',
            'title': 'Dependency',
            'description': 'A dependency',
          };
        } else if (path == '/cf/mods/77/files/900') {
          data = {'data': curseVersion()};
        } else if (path == '/cf/mods/77') {
          data = {
            'data': {
              'id': 77,
              'slug': 'cf-demo',
              'name': 'CF Demo',
              'links': {
                'websiteUrl':
                    'https://www.curseforge.com/minecraft/mc-mods/cf-demo',
              },
            },
          };
        } else {
          request.response.statusCode = 404;
          data = {};
        }
        request.response.write(jsonEncode(data));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    installer.dispose();
    catalog.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
    'cancelling a Mod commit restores installed files and the management index',
    () async {
      var cancelOnce = true;
      late ContentInstaller transactional;
      transactional = ContentInstaller(
        platform: const HostPlatform('windows', 'x86_64'),
        supportDirectory: directory.path,
        settings: settings.copy,
        busy: () =>
            transactional.tasks.any((t) => t.state == ContentTaskState.running),
        catalogFactory: (value) => CommunityCatalog(
          value,
          network: FixtureNetwork(value),
          modrinthBase: '$base/mr',
          curseforgeBase: '$base/cf',
        ),
        onInstalled: (_) async {},
        onChanged: () {
          final task = transactional.tasks.firstOrNull;
          if (cancelOnce && task?.stage == '安装模组' && task?.done == 1) {
            cancelOnce = false;
            task!.token.cancel();
          }
        },
      );
      addTearDown(transactional.dispose);
      final folder = Directory(p.join(directory.path, 'chosen'));
      await folder.create();
      final main = File(p.join(folder.path, 'chosen.jar'));
      await main.writeAsString('original main');
      final dependency = File(p.join(folder.path, 'dependency.jar'));
      await dependency.writeAsString('original dependency');
      final previous = File(p.join(folder.path, 'previous.jar'));
      await previous.writeAsString('owned previous');
      final index = File(p.join(folder.path, '.fyl-managed-mods.json'));
      final rawIndex = jsonEncode({
        'modrinth:demo': {
          'path': 'previous.jar',
          'sha1': sha1.convert(utf8.encode('owned previous')).toString(),
        },
      });
      await index.writeAsString(rawIndex);
      final info = project();
      final release = (await catalog.versions(
        info,
        CancellationToken(),
        minecraft: '1.21.1',
        loader: 'fabric',
      )).versions.single;
      final target = GameInstance(
        id: 'game',
        name: 'Game',
        version: '1.21.1',
        root: directory.path,
        isolated: true,
        javaMajor: 21,
        components: 'Fabric 0.16.10',
      );
      final task = await transactional.installMod(
        info,
        release,
        target,
        main.path,
      );
      expect(task.state, ContentTaskState.cancelled);
      expect(await main.readAsString(), 'original main');
      expect(await dependency.readAsString(), 'original dependency');
      expect(await index.readAsString(), rawIndex);
      expect(await previous.exists(), isTrue);
      await transactional.retry(task);
      expect(task.state, ContentTaskState.completed, reason: task.error);
      expect(await main.readAsBytes(), jar);
      expect(await dependency.readAsBytes(), jar);
      expect(await previous.exists(), isFalse);
      expect(
        (jsonDecode(await index.readAsString())
            as Json)['modrinth:demo']['path'],
        'chosen.jar',
      );
    },
  );

  for (final isolated in [true, false]) {
    test(
      'a cancelled pack rolls back game data and retries without a conflicting base folder (isolated=$isolated)',
      () async {
        await writePack(mrManifest());
        var cancelOnce = true, baseCalls = 0;
        late ContentInstaller transactional;
        transactional = ContentInstaller(
          platform: const HostPlatform('windows', 'x86_64'),
          supportDirectory: directory.path,
          settings: settings.copy,
          busy: () => transactional.tasks.any(
            (t) => t.state == ContentTaskState.running,
          ),
          catalogFactory: (value) => CommunityCatalog(
            value,
            network: FixtureNetwork(value),
            modrinthBase: '$base/mr',
            curseforgeBase: '$base/cf',
          ),
          onInstalled: (game) async => installed.add(game),
          onChanged: () {
            final task = transactional.tasks.firstOrNull;
            if (cancelOnce && task?.stage == '应用整合包配置' && task?.done == 1) {
              cancelOnce = false;
              task!.token.cancel();
            }
          },
          installBase: (task, token, update) async {
            final game = GameInstance(
              id: 'base-$baseCalls',
              name: task.instanceName,
              version: task.version.id,
              root: directory.path,
              isolated: task.settings.isolateVersions,
              javaMajor: 21,
            );
            if (await Directory(game.versionDirectory).exists()) {
              throw StateError('Existing base directory');
            }
            baseCalls++;
            await File(game.metadataPath).parent.create(recursive: true);
            await File(
              game.metadataPath,
            ).writeAsString(jsonEncode({'id': game.name}));
            await File(game.clientJarPath).writeAsString('base client');
            return game;
          },
        );
        addTearDown(transactional.dispose);
        final oldMod = File(p.join(directory.path, 'mods', 'demo.jar'));
        await oldMod.parent.create(recursive: true);
        await oldMod.writeAsString('shared old mod');
        final oldConfig = File(p.join(directory.path, 'config', 'test.cfg'));
        await oldConfig.parent.create(recursive: true);
        await oldConfig.writeAsString('shared old config');
        final info = project(kind: ContentKind.modpack);
        final release = packRelease(ContentSource.modrinth);
        final plan = await transactional.preparePack(
          info,
          release,
          CancellationToken(),
        );
        final task = await transactional.installPack(
          info,
          release,
          plan,
          'Retry Pack',
          isolated: isolated,
        );
        expect(task.state, ContentTaskState.cancelled);
        expect(installed, isEmpty);
        expect(
          await Directory(
            p.join(directory.path, 'versions', 'Retry Pack'),
          ).exists(),
          isFalse,
        );
        expect(await oldMod.readAsString(), 'shared old mod');
        expect(await oldConfig.readAsString(), 'shared old config');
        await transactional.retry(task);
        expect(task.state, ContentTaskState.completed, reason: task.error);
        expect(baseCalls, 2);
        expect(installed, hasLength(1));
        expect(
          await File(
            p.join(installed.single.gameDirectory, 'mods', 'demo.jar'),
          ).readAsBytes(),
          jar,
        );
      },
    );
  }

  test(
    'both providers search with exact filters and missing CurseForge key preserves Modrinth results',
    () async {
      final result = await catalog.search(
        kind: ContentKind.mod,
        query: 'demo',
        minecraft: '1.21.1',
        loader: 'fabric',
      );
      expect(
        result.projects.map((p) => p.source).toSet(),
        ContentSource.values.toSet(),
      );
      expect(result.hasMore, isTrue);
      settings.curseforgeApiKey = '';
      final fallback = await catalog.search(
        kind: ContentKind.mod,
        minecraft: '1.21.1',
      );
      expect(fallback.projects.single.source, ContentSource.modrinth);
      expect(fallback.notices.single, contains('API Key'));
      expect(settings.toJson().containsKey('curseforgeApiKey'), isFalse);
      settings.curseforgeApiKey = 'private-key';
      expect(settings.copy().curseforgeApiKey, 'private-key');
    },
  );
  test(
    'mod installation resolves required dependencies and writes only to chosen destination',
    () async {
      final release = (await catalog.versions(
        project(),
        CancellationToken(),
        minecraft: '1.21.1',
        loader: 'fabric',
      )).versions.single;
      final target = GameInstance(
        id: 'game',
        name: 'Game',
        version: '1.21.1',
        root: directory.path,
        isolated: true,
        javaMajor: 21,
        components: 'Fabric 0.16.10',
      );
      final destination = p.join(
        directory.path,
        'selected-folder',
        'custom-name.jar',
      );
      final task = await installer.installMod(
        project(),
        release,
        target,
        destination,
      );
      expect(task.state, ContentTaskState.completed);
      expect(await File(destination).readAsBytes(), jar);
      expect(
        await File(
          p.join(p.dirname(destination), 'dependency.jar'),
        ).readAsBytes(),
        jar,
      );
      expect(
        await Directory(p.join(target.gameDirectory, 'mods')).exists(),
        isFalse,
      );
      expect(installed, isEmpty);
    },
  );
  test(
    'mrpack installs pinned loader, required client files and layered overrides before registration',
    () async {
      settings.verifyDownloads = false;
      await writePack(
        mrManifest(),
        extra: {
          'overrides/config/test.cfg': 'base',
          'client-overrides/config/test.cfg': 'client',
          'server-overrides/config/test.cfg': 'server',
        },
      );
      final info = project(kind: ContentKind.modpack);
      final release = packRelease(ContentSource.modrinth);
      final plan = await installer.preparePack(
        info,
        release,
        CancellationToken(),
      );
      expect(plan.files, hasLength(2));
      expect(plan.files.where((f) => f.optional), hasLength(1));
      final task = await installer.installPack(
        info,
        release,
        plan,
        'Installed',
        isolated: true,
      );
      expect(task.state, ContentTaskState.completed);
      expect(baseTask!.options.loader!.version, '0.16.10');
      expect(baseTask!.version.id, '1.21.1');
      final game = installed.single;
      expect(
        await File(
          p.join(game.gameDirectory, 'mods', 'demo.jar'),
        ).readAsBytes(),
        jar,
      );
      expect(
        await File(p.join(game.gameDirectory, 'mods', 'optional.jar')).exists(),
        isFalse,
      );
      expect(
        await File(
          p.join(game.gameDirectory, 'config', 'test.cfg'),
        ).readAsString(),
        'client',
      );
      expect(
        await File(p.join(game.launcherDirectory, 'modpack.json')).exists(),
        isTrue,
      );
    },
  );
  test(
    'restricted CurseForge files wait for hash-verified manual completion',
    () async {
      restricted = true;
      await writePack({
        'manifestType': 'minecraftModpack',
        'manifestVersion': 1,
        'name': 'CF Pack',
        'version': '1',
        'minecraft': {'version': '1.21.1', 'modLoaders': []},
        'files': [
          {'projectID': 77, 'fileID': 900, 'required': true},
        ],
        'overrides': 'overrides',
      }, curse: true);
      final info = project(
        source: ContentSource.curseforge,
        kind: ContentKind.modpack,
      );
      final release = packRelease(ContentSource.curseforge);
      final plan = await installer.preparePack(
        info,
        release,
        CancellationToken(),
      );
      final task = await installer.installPack(
        info,
        release,
        plan,
        'CF Pack',
        isolated: true,
      );
      expect(task.state, ContentTaskState.waiting);
      expect(installed, isEmpty);
      expect(task.missing.single.website, contains('/cf-demo/files/900'));
      final selected = await File(
        p.join(directory.path, 'user-download.jar'),
      ).writeAsBytes(jar);
      expect(await installer.supplyFiles(task, [selected.path]), 1);
      expect(task.state, ContentTaskState.completed);
      expect(installed, hasLength(1));
    },
  );
  test(
    'pack parser rejects traversal, conflicting loaders and unsupported Quilt',
    () async {
      final manifest = mrManifest();
      final archive = await writePack(
        manifest,
        extra: {'overrides/../../outside': 'bad'},
      );
      await expectLater(inspectModpack(archive), throwsFormatException);
      manifest['dependencies'] = {
        'minecraft': '1.21.1',
        'quilt-loader': '0.28',
      };
      final quilt = await writePack(manifest);
      await expectLater(inspectModpack(quilt), throwsFormatException);
      manifest['dependencies'] = {
        'minecraft': '1.21.1',
        'forge': '52.0',
        'fabric-loader': '0.16.10',
      };
      await expectLater(
        inspectModpack(await writePack(manifest)),
        throwsFormatException,
      );
    },
  );
}
