import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/download_source.dart';
import 'package:free_your_launcher/core/install_options.dart';
import 'package:free_your_launcher/core/mod_catalog.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/ui/settings_page.dart';
import 'package:free_your_launcher/ui/theme.dart';

class MirrorCatalogNetwork extends OfficialNetwork {
  MirrorCatalogNetwork(super.settings);
  @override
  Future<dynamic> jsonValue(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async => url.contains('/forge/minecraft/')
      ? [
          {
            'version': '47.2.0',
            'files': [
              {'category': 'installer', 'format': 'jar'},
            ],
          },
          {'version': '47.1.0', 'files': <Json>[]},
        ]
      : [
          {'filename': 'OptiFine_1.20.1_HD_U_I6.jar'},
          {'filename': '../invalid.jar'},
          {'mcversion': '1.20.1', 'type': 'HD_U', 'patch': 'I7_pre1'},
        ];
}

void main() {
  testWidgets('the download source dropdown saves the selected mirror', (
    tester,
  ) async {
    final temporary = await tester.runAsync(
      () => Directory.systemTemp.createTemp('fyl-source-settings-'),
    );
    final controller = LauncherController(
      supportDirectory: temporary!.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    final key = GlobalKey<SettingsPageState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: const LauncherColors(false).material,
        home: FTheme(
          data: const LauncherColors(false).forui,
          child: Scaffold(
            body: SettingsPage(
              key: key,
              controller: controller,
              onDirty: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载与版本'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SelectBox<DownloadSource>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('BMCLAPI').last);
    await tester.pumpAndSettle();
    expect(key.currentState!.draft.downloadSource, DownloadSource.bmclapi);
    await tester.runAsync(() => key.currentState!.save());
    await tester.pumpAndSettle();
    expect(controller.settings.downloadSource, DownloadSource.bmclapi);
    final restored = LauncherController(
      supportDirectory: temporary.path,
      platform: controller.platform,
    );
    await tester.runAsync(restored.initialize);
    expect(restored.settings.downloadSource, DownloadSource.bmclapi);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    restored.dispose();
    await tester.runAsync(() => temporary.delete(recursive: true));
  });
  test(
    'source selection persists, copies and defaults to the official source',
    () {
      final settings = LauncherSettings(gameRoot: Directory.systemTemp.path);
      expect(settings.downloadSource, DownloadSource.official);
      settings.downloadSource = DownloadSource.bmclapi;
      expect(settings.copy().downloadSource, DownloadSource.bmclapi);
      expect(
        LauncherSettings.fromJson(
          settings.toJson(),
          settings.gameRoot,
        ).downloadSource,
        DownloadSource.bmclapi,
      );
      expect(
        LauncherSettings.fromJson({
          'downloadSource': 'future-source',
        }, settings.gameRoot).downloadSource,
        DownloadSource.official,
      );
    },
  );
  test(
    'BMCLAPI maps game, Java, assets and loader URLs without touching community or authentication',
    () {
      final mappings = {
        'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json':
            '/mc/game/version_manifest_v2.json',
        'https://piston-data.mojang.com/v1/objects/hash/client.jar':
            '/v1/objects/hash/client.jar',
        'https://resources.download.minecraft.net/ab/abcdef':
            '/assets/ab/abcdef',
        'https://libraries.minecraft.net/org/example/library.jar':
            '/maven/org/example/library.jar',
        'https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml':
            '/maven/net/minecraftforge/forge/maven-metadata.xml',
        'https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml':
            '/maven/net/neoforged/neoforge/maven-metadata.xml',
        'https://meta.fabricmc.net/v2/versions/loader/1.20.1':
            '/fabric-meta/v2/versions/loader/1.20.1',
        'https://maven.fabricmc.net/net/fabricmc/example.jar':
            '/maven/net/fabricmc/example.jar',
        'https://repo.maven.apache.org/maven2/org/example/library.jar':
            '/maven/org/example/library.jar',
      };
      for (final entry in mappings.entries) {
        expect(
          sourceDownloadUri(
            Uri.parse(entry.key),
            DownloadSource.bmclapi,
          ).toString(),
          'https://$bmclMirrorHost${entry.value}',
        );
        expect(
          sourceDownloadUri(
            Uri.parse(entry.key),
            DownloadSource.official,
          ).toString(),
          entry.key,
        );
      }
      for (final url in [
        'https://api.modrinth.com/v2/search',
        'https://api.curseforge.com/v1/mods',
        'https://login.microsoftonline.com/consumers/oauth2/v2.0/token',
      ]) {
        expect(
          sourceDownloadUri(Uri.parse(url), DownloadSource.bmclapi).toString(),
          url,
        );
      }
    },
  );
  test(
    'mirror CDN redirects exclude private addresses, credentials and non-HTTPS URLs',
    () {
      for (final url in [
        'http://cdn.example.com/file',
        'https://localhost/file',
        'https://127.0.0.1/file',
        'https://10.0.0.2/file',
        'https://172.16.0.1/file',
        'https://192.168.1.1/file',
        'https://[::1]/file',
        'https://[::ffff:127.0.0.1]/file',
        'https://[fc00::1]/file',
        'https://user:password@cdn.example.com/file',
      ]) {
        expect(isPublicMirrorRedirect(Uri.parse(url)), isFalse, reason: url);
      }
      expect(
        isPublicMirrorRedirect(Uri.parse('https://cdn.example.com/file')),
        isTrue,
      );
    },
  );
  test(
    'OptiFine uses BMCLAPI metadata and downloads when the mirror is selected',
    () async {
      final network = MirrorCatalogNetwork(
        LauncherSettings(
          gameRoot: Directory.systemTemp.path,
          downloadSource: DownloadSource.bmclapi,
        ),
      );
      addTearDown(network.close);
      final catalog = ModCatalog(network);
      final versions = await catalog.optifine('1.20.1', CancellationToken());
      expect(versions.map((version) => version.fileName), [
        'OptiFine_1.20.1_HD_U_I6.jar',
        'OptiFine_1.20.1_HD_U_I7_pre1.jar',
      ]);
      expect(
        await catalog.optifineDownload(
          const OptiFineVersion('preview_OptiFine_1.20.1_HD_U_I7_pre1.jar'),
          CancellationToken(),
        ),
        'https://$bmclMirrorHost/optifine/1.20.1/HD_U/I7_pre1',
      );
      final forge = await catalog.loaders(
        ModLoader.forge,
        '1.20.1',
        CancellationToken(),
      );
      expect(forge.single.version, '47.2.0');
      expect(forge.single.coordinate, 'net.minecraftforge:forge:1.20.1-47.2.0');
    },
  );
}
