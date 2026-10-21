import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/content_installer.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/resource_packs.dart';
import 'package:path/path.dart' as p;

class ResourceSearchNetwork extends OfficialNetwork {
  final requests = <Uri>[];
  ResourceSearchNetwork(super.settings);
  @override
  Future<dynamic> jsonValue(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async {
    final uri = Uri.parse(url);
    requests.add(uri);
    if (uri.path.endsWith('/version')) return <Json>[];
    if (uri.host == 'api.modrinth.com') {
      return {'hits': <Json>[], 'total_hits': 0};
    }
    return {
      'data': <Json>[],
      'pagination': {'totalCount': 0},
    };
  }
}

void main() {
  late Directory temporary;
  late HttpServer server;
  late List<int> bytes;
  late GameInstance target;
  late ContentInstaller installer;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-resources-');
    target = GameInstance(
      id: 'vanilla',
      name: 'Vanilla',
      version: '1.21.1',
      root: temporary.path,
      isolated: true,
      javaMajor: 21,
    );
    bytes = ZipEncoder().encode(
      Archive()
        ..addFile(
          ArchiveFile.string(
            'pack.mcmeta',
            '{"pack":{"pack_format":48,"description":"Test"}}',
          ),
        )
        ..addFile(ArchiveFile.string('shaders/main.fsh', 'shader')),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.add(bytes);
      await request.response.close();
    });
    final settings = LauncherSettings(
      gameRoot: temporary.path,
      downloadRetries: 0,
    );
    installer = ContentInstaller(
      platform: const HostPlatform('windows', 'x86_64'),
      supportDirectory: temporary.path,
      settings: settings.copy,
      onChanged: () {},
      onInstalled: (_) async {},
      busy: () => false,
      catalogFactory: (settings) => CommunityCatalog(
        settings,
        network: OfficialNetwork(settings, allowLocalhost: true),
      ),
    );
  });
  tearDown(() async {
    installer.dispose();
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });
  ContentProject project(ContentKind kind) => ContentProject(
    source: ContentSource.modrinth,
    kind: kind,
    id: 'resource',
    slug: 'resource',
    name: 'Test Resource',
    summary: '',
    author: '',
    website: 'https://modrinth.com',
  );
  ContentVersion release() => ContentVersion(
    source: ContentSource.modrinth,
    id: 'v1',
    projectId: 'resource',
    name: 'Resource 1',
    number: '1',
    published: DateTime(2026),
    gameVersions: ['1.21.1'],
    files: [
      ContentFile(
        name: 'resource.zip',
        projectId: 'resource',
        id: 'v1',
        urls: ['http://127.0.0.1:${server.port}/artifact'],
        size: bytes.length,
        hashes: {'sha512': sha512.convert(bytes).toString()},
      ),
    ],
  );
  for (final kind in ContentKind.values.where((kind) => kind.isResource)) {
    test(
      '$kind installs into the selected vanilla version without a mod loader',
      () async {
        final world = p.join(target.gameDirectory, 'saves', 'World');
        final destination = p.join(
          resourceDirectory(target, kind, world: world),
          'resource.zip',
        );
        final task = await installer.installResource(
          project(kind),
          release(),
          target,
          destination,
        );
        expect(task.state, ContentTaskState.completed, reason: task.error);
        expect(task.kind, kind);
        expect(await File(destination).readAsBytes(), bytes);
        expect(
          await File(
            p.join(p.dirname(destination), '.fyl-managed-${kind.name}.json'),
          ).exists(),
          isTrue,
        );
        expect(
          await Directory(p.join(target.gameDirectory, 'mods')).exists(),
          isFalse,
        );
      },
    );
  }
  test('invalid resource archives never replace an installed pack', () async {
    bytes = ZipEncoder().encode(
      Archive()..addFile(ArchiveFile.string('unrelated.txt', 'not a pack')),
    );
    final file = File(
      p.join(target.gameDirectory, 'resourcepacks', 'resource.zip'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString('keep original');
    final task = await installer.installResource(
      project(ContentKind.resourcepack),
      release(),
      target,
      file.path,
    );
    expect(task.state, ContentTaskState.failed);
    expect(await file.readAsString(), 'keep original');
  });
  test(
    'incompatible resource versions are rejected before a download task starts',
    () async {
      await expectLater(
        installer.installResource(
          project(ContentKind.shader),
          release(),
          GameInstance(
            id: 'older',
            name: 'Older',
            version: '1.20.1',
            root: target.root,
            isolated: true,
            javaMajor: 17,
          ),
          p.join(temporary.path, 'wrong.zip'),
        ),
        throwsStateError,
      );
      expect(installer.tasks, isEmpty);
    },
  );
  test('data pack world selection includes only actual worlds', () async {
    final world = File(
      p.join(target.gameDirectory, 'saves', 'My World', 'level.dat'),
    );
    await world.parent.create(recursive: true);
    await world.writeAsString('world');
    await Directory(
      p.join(target.gameDirectory, 'saves', 'not-a-world'),
    ).create();
    expect(
      (await dataPackWorlds(target)).map((world) => p.basename(world.path)),
      ['My World'],
    );
  });
  test(
    'new resource categories use distinct provider filters and datapack file types',
    () async {
      final settings = LauncherSettings(
        gameRoot: temporary.path,
        curseforgeApiKey: 'test-key',
      );
      final network = ResourceSearchNetwork(settings);
      final catalog = CommunityCatalog(settings, network: network);
      addTearDown(catalog.close);
      for (final kind in ContentKind.values.where((kind) => kind.isResource)) {
        network.requests.clear();
        await catalog.search(kind: kind, minecraft: '1.21.1');
        final mr = network.requests.firstWhere(
          (uri) => uri.host == 'api.modrinth.com',
        );
        final cf = network.requests.firstWhere(
          (uri) => uri.host == 'api.curseforge.com',
        );
        final facets = (jsonDecode(mr.queryParameters['facets']!) as List)
            .expand((value) => value as List);
        final projectType = switch (kind) {
          ContentKind.datapack => 'datapack',
          ContentKind.resourcepack => 'resourcepack',
          ContentKind.shader => 'shader',
          _ => throw StateError('Unexpected test kind'),
        };
        expect(facets, contains('project_type:$projectType'));
        if (kind == ContentKind.datapack) {
          expect(facets, isNot(contains('project_type:mod')));
        }
        expect(cf.queryParameters['classId'], '${kind.curseClassId}');
      }
      await catalog.versions(
        project(ContentKind.datapack),
        CancellationToken(),
      );
      expect(jsonDecode(network.requests.last.queryParameters['loaders']!), [
        'datapack',
      ]);
    },
  );
}
