import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/download_source.dart';
import 'package:free_your_launcher/core/install_options.dart';
import 'package:free_your_launcher/core/instance_tools.dart';
import 'package:free_your_launcher/core/local_mods.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/mod_catalog.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/pack_import.dart';
import 'package:path/path.dart' as p;
import 'instance_tools_test.dart' show RepairFixtureNetwork;
import 'resource_packs_test.dart' show ResourceSearchNetwork;

class QuiltNetwork extends RepairFixtureNetwork {
  QuiltNetwork(LauncherSettings settings)
    : super(settings, utf8.encode('client'));
  final profiles = <String>[];
  final libraries = <DownloadFile>[];
  @override
  Future<dynamic> jsonValue(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async => [
    for (final v in ['0.20.0-beta.9', '0.29.0', '0.30.1', '0.30.2-beta.1'])
      {
        'loader': {'version': v, 'maven': 'org.quiltmc:quilt-loader:$v'},
      },
  ];
  @override
  Future<Json> json(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async {
    if (!url.startsWith('https://meta.quiltmc.org/')) {
      return super.json(url, expectedHash: expectedHash, token: token);
    }
    profiles.add(url);
    return {
      'id': 'quilt-loader-0.30.1-1.21.1',
      'inheritsFrom': '1.21.1',
      'mainClass': 'org.quiltmc.loader.impl.launch.knot.KnotClient',
      'arguments': {'game': <String>[], 'jvm': <String>[]},
      'libraries': [
        for (final name in ['quilt-loader:0.30.1', 'hashed:1.21.1'])
          {
            'name': 'org.quiltmc:$name',
            'url': 'https://maven.quiltmc.org/repository/release/',
          },
        {
          'name': 'net.fabricmc:intermediary:1.21.1',
          'url': 'https://maven.fabricmc.net/',
        },
      ],
    };
  }

  @override
  Future<void> downloadAll(
    List<DownloadFile> files,
    CancellationToken token, {
    void Function(int, int, String)? onProgress,
    void Function(int)? onBytes,
    void Function(int)? onCachedBytes,
  }) async {
    libraries.addAll(files);
    await super.downloadAll(
      files,
      token,
      onProgress: onProgress,
      onBytes: onBytes,
      onCachedBytes: onCachedBytes,
    );
  }
}

void main() {
  test('Quilt filters use both providers native loader identifiers', () async {
    final settings = LauncherSettings(
      gameRoot: Directory.systemTemp.path,
      curseforgeApiKey: 'fixture',
    );
    final network = ResourceSearchNetwork(settings);
    final catalog = CommunityCatalog(settings, network: network);
    addTearDown(catalog.close);
    await catalog.search(
      kind: ContentKind.mod,
      minecraft: '1.21.1',
      loader: 'quilt',
    );
    final mr = network.requests.firstWhere((u) => u.host == 'api.modrinth.com');
    final cf = network.requests.firstWhere(
      (u) => u.host == 'api.curseforge.com',
    );
    expect(mr.queryParameters['facets'], contains('categories:quilt'));
    expect(cf.queryParameters['modLoaderType'], '5');
  });
  test(
    'Quilt versions are sorted independently of official API order',
    () async {
      final network = QuiltNetwork(
        LauncherSettings(gameRoot: Directory.systemTemp.path),
      );
      addTearDown(network.close);
      final versions = await ModCatalog(
        network,
      ).loaders(ModLoader.quilt, '1.21.1', CancellationToken());
      expect(versions.map((v) => v.version), [
        '0.30.1',
        '0.29.0',
        '0.30.2-beta.1',
        '0.20.0-beta.9',
      ]);
      expect(versions.first.coordinate, 'org.quiltmc:quilt-loader:0.30.1');
      expect(versions.first.stable, isTrue);
    },
  );

  test(
    'Quilt installs launchable metadata, downloads mappings, and round trips packs',
    () async {
      final root = await Directory.systemTemp.createTemp('fyl-quilt-');
      addTearDown(() => root.delete(recursive: true));
      final settings = LauncherSettings(
        gameRoot: root.path,
        automaticJava: false,
        javaPath: 'java',
        username: 'Test_User',
      );
      final network = QuiltNetwork(settings);
      addTearDown(network.close);
      const options = InstallOptions(
        loader: LoaderVersion(
          ModLoader.quilt,
          '0.30.1',
          coordinate: 'org.quiltmc:quilt-loader:0.30.1',
        ),
      );
      final task = InstallTask(
        MinecraftVersion.fromJson({
          'id': '1.21.1',
          'type': 'release',
          'url': 'https://example.test/version',
          'releaseTime': '2024-01-01T00:00:00Z',
        }),
        'Quilt Game',
        settings,
        options: options,
      );
      final platform = await HostPlatform.detect();
      final instance = await MinecraftInstaller(
        platform,
        network,
      ).install(task, CancellationToken(), () {});
      expect(instanceModLoader(instance), 'quilt');
      expect(
        InstallOptions.fromJson(instance.installation).loader!.loader,
        ModLoader.quilt,
      );
      expect(network.profiles.single, endsWith('/1.21.1/0.30.1/profile/json'));
      expect(
        network.libraries.map((f) => f.path),
        containsAll([
          p.join(
            root.path,
            'libraries',
            'org',
            'quiltmc',
            'hashed',
            '1.21.1',
            'hashed-1.21.1.jar',
          ),
          p.join(
            root.path,
            'libraries',
            'net',
            'fabricmc',
            'intermediary',
            '1.21.1',
            'intermediary-1.21.1.jar',
          ),
        ]),
      );
      final command = await MinecraftRunner(
        platform,
      ).prepare(instance, settings);
      expect(
        command.arguments,
        contains('org.quiltmc.loader.impl.launch.knot.KnotClient'),
      );
      final output = p.join(root.path, 'export.mrpack');
      await exportInstancePack(
        instance,
        output,
        CancellationToken(),
        folders: {},
        version: '1.0',
      );
      final plan = await inspectModpack(output);
      expect(plan.loader, ModLoader.quilt);
      expect(plan.loaderVersion, '0.30.1');
      final archive = Archive()
        ..add(
          ArchiveFile.string(
            'quilt.mod.json',
            jsonEncode({
              'quilt_loader': {
                'id': 'example',
                'version': '1.2',
                'metadata': {
                  'name': 'Example Quilt Mod',
                  'description': 'Quilt description',
                },
              },
            }),
          ),
        );
      final mod = File(p.join(instance.gameDirectory, 'mods', 'quilt.jar'));
      await mod.parent.create(recursive: true);
      await mod.writeAsBytes(ZipEncoder().encode(archive));
      final info = readLocalMod(mod.path);
      expect(info.loader, 'Quilt');
      expect(info.name, 'Example Quilt Mod');
      expect(info.description, 'Quilt description');
      expect(info.id, 'example');
      expect(info.version, '1.2');
    },
  );

  test(
    'Quilt keeps working through official endpoints when BMCLAPI is selected',
    () {
      for (final url in [
        'https://meta.quiltmc.org/v3/versions/loader/1.21.1',
        'https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-loader/0.30.1/quilt-loader-0.30.1.jar',
      ]) {
        expect(
          sourceDownloadUri(Uri.parse(url), DownloadSource.bmclapi).toString(),
          url,
        );
      }
      expect(
        const InstallOptions(
          loader: LoaderVersion(ModLoader.quilt, '0.30.1'),
          optifine: OptiFineVersion('OptiFine_1.20.1_HD_U_I6.jar'),
        ).validationError,
        contains('Quilt'),
      );
    },
  );
}
