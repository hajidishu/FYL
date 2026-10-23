import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/minecraft.dart' show writeJson;
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/pack_origin.dart';
import 'package:free_your_launcher/core/pack_updates.dart';
import 'package:free_your_launcher/ui/pack_update_dialog.dart';
import 'package:free_your_launcher/ui/theme.dart';

const _archive = 'original imported modpack fixture';

class _SlugNetwork extends OfficialNetwork {
  bool wrongKind = false;
  _SlugNetwork(super.settings);
  @override
  Future<dynamic> jsonValue(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async {
    final uri = Uri.parse(url);
    if (uri.path.endsWith('/mods/search')) {
      expect(uri.queryParameters['slug'], 'ftb-stoneblock-4');
      expect(uri.queryParameters['classId'], '4471');
      expect(uri.queryParameters.containsKey('searchFilter'), false);
      return {
        'data': [
          {'id': 123, 'slug': 'ftb-stoneblock-4'},
        ],
      };
    }
    expect(uri.path, '/v1/mods/123');
    return {
      'data': {
        'id': 123,
        'name': 'FTB StoneBlock 4',
        'slug': 'ftb-stoneblock-4',
        'summary': '',
        'classId': wrongKind ? 6 : 4471,
        'links': {
          'websiteUrl':
              'https://www.curseforge.com/minecraft/modpacks/ftb-stoneblock-4',
        },
      },
    };
  }
}

class _OriginCatalog extends CommunityCatalog {
  final bool identify, wrongHash;
  final versionRequests = <String>[];
  _OriginCatalog(
    super.settings, {
    this.identify = false,
    this.wrongHash = false,
  });
  static const pack = ContentProject(
    source: ContentSource.modrinth,
    kind: ContentKind.modpack,
    id: 'pack-project',
    slug: 'example-pack',
    name: 'Example Pack',
    summary: '',
    author: '',
    website: 'https://modrinth.com/modpack/example-pack',
  );
  ContentVersion release(String id) => ContentVersion(
    source: ContentSource.modrinth,
    projectId: pack.id,
    id: id,
    name: id,
    number: id == 'old' ? '1.0.0' : '2.0.0',
    published: DateTime.utc(id == 'old' ? 2024 : 2025),
    gameVersions: ['1.21.1'],
    files: [
      ContentFile(
        name: 'pack.mrpack',
        hashes: {
          'sha1': wrongHash
              ? '0' * 40
              : sha1.convert(utf8.encode(_archive)).toString(),
        },
      ),
    ],
  );
  @override
  Future<ContentProject> project(
    ContentSource source,
    String id,
    ContentKind kind,
    CancellationToken token,
  ) async => pack;
  @override
  Future<Map<String, ContentVersion>> versionsFromHashes(
    List<String> hashes,
    CancellationToken token, {
    String? minecraft,
    String? loader,
    List<String>? channels,
  }) async => identify ? {hashes.single: release('old')} : {};
  @override
  Future<ContentVersionPage> versions(
    ContentProject project,
    CancellationToken token, {
    String minecraft = '',
    String? loader,
    int page = 0,
  }) async => ContentVersionPage([release('new'), release('old')]);
  @override
  Future<ContentVersion> version(
    ContentSource source,
    String projectId,
    String versionId,
    CancellationToken token,
  ) async {
    versionRequests.add(versionId);
    if (versionId != 'old' && versionId != 'new') {
      throw const FormatException('Unknown fixture version');
    }
    return release(versionId);
  }

  @override
  Future<String> versionNotes(
    ContentVersion version,
    CancellationToken token,
  ) async => 'Fixture release notes';
}

void main() {
  late Directory temporary;
  late LauncherController controller;
  late GameInstance instance;
  late Json record;
  late _OriginCatalog catalog;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-pack-origin-');
    catalog = _OriginCatalog(LauncherSettings(gameRoot: temporary.path));
    controller = LauncherController(
      supportDirectory: temporary.path,
      platform: const HostPlatform('windows', 'x86_64'),
      communityCatalogFactory: (_) => catalog,
    );
    instance = GameInstance(
      id: 'imported',
      name: 'Imported Pack',
      version: '1.21.1',
      root: p.join(temporary.path, 'game'),
      isolated: true,
      javaMajor: 21,
      installation: const {'modpack': true},
    );
    controller.instances.add(instance);
    final hash = sha256.convert(utf8.encode(_archive)).toString();
    record = {
      'source': 'curseforge',
      'projectId': 'local-$hash',
      'releaseId': hash,
      'version': '1.0.0',
      'minecraft': '1.21.1',
      'managedFiles': ['mods/example.jar'],
    };
    await writeJson(
      File(p.join(instance.launcherDirectory, 'modpack.json')),
      record,
    );
  });
  tearDown(() async {
    controller.dispose();
    catalog.close();
    await temporary.delete(recursive: true);
  });

  Future<void> cacheArchive() async {
    final file = File(
      p.join(
        temporary.path,
        'cache',
        'local-packs',
        record['releaseId'] as String,
        'pack.zip',
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(_archive);
  }

  test(
    'linking an imported pack preserves baseline provenance without inventing an installed release',
    () {
      final linked = linkedPackRecord(record, _OriginCatalog.pack);
      expect(linked['originSource'], 'curseforge');
      expect(linked['originReleaseId'], record['releaseId']);
      expect(linked['importedArchiveSha256'], record['releaseId']);
      expect(linked['releaseId'], '');
      expect(linked['version'], '1.0.0');
      expect(linked['managedFiles'], record['managedFiles']);
      expect(hasOnlinePackOrigin(linked), true);
    },
  );

  test(
    'references accept pack links and reject lookalike hosts and mod links',
    () {
      final reference = parsePackProjectReference(
        ContentSource.curseforge,
        'https://modrinth.com/modpack/example-pack/version/abc',
      );
      expect(reference.source, ContentSource.modrinth);
      expect(reference.id, 'example-pack');
      expect(
        parsePackProjectReference(
          ContentSource.modrinth,
          'https://www.curseforge.com/minecraft/modpacks/example-pack',
        ).source,
        ContentSource.curseforge,
      );
      for (final url in [
        'http://modrinth.com/modpack/example-pack',
        'https://modrinth.com.evil.invalid/modpack/example-pack',
        'https://modrinth.com/mod/example',
        'https://user:password@modrinth.com/modpack/example-pack',
      ]) {
        expect(
          () => parsePackProjectReference(ContentSource.modrinth, url),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'archive identity requires matching SHA-1, not just a provider lookup key',
    () async {
      await cacheArchive();
      final recognized = _OriginCatalog(controller.settings, identify: true);
      addTearDown(recognized.close);
      final match = await identifyImportedPack(
        record,
        temporary.path,
        recognized,
        CancellationToken(),
      );
      expect(match!.project.id, _OriginCatalog.pack.id);
      expect(match.version.id, 'old');
      final mismatch = _OriginCatalog(
        controller.settings,
        identify: true,
        wrongHash: true,
      );
      addTearDown(mismatch.close);
      expect(
        await identifyImportedPack(
          record,
          temporary.path,
          mismatch,
          CancellationToken(),
        ),
        isNull,
      );
      expect(
        (await readPackRecord(instance))['projectId'],
        record['projectId'],
      );
    },
  );

  test(
    'CurseForge project links use exact slug lookup and validate the project class',
    () async {
      final settings = controller.settings.copy()
        ..curseforgeApiKey = 'fixture-api-key';
      final network = _SlugNetwork(settings);
      final provider = CommunityCatalog(settings, network: network);
      addTearDown(provider.close);
      final reference = parsePackProjectReference(
        ContentSource.modrinth,
        'https://www.curseforge.com/minecraft/modpacks/ftb-stoneblock-4',
      );
      final project = await resolvePackProject(
        provider,
        reference,
        CancellationToken(),
      );
      expect(project.id, '123');
      expect(project.kind, ContentKind.modpack);
      network.wrongKind = true;
      await expectLater(
        resolvePackProject(provider, reference, CancellationToken()),
        throwsFormatException,
      );
    },
  );

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1154, 756);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: const LauncherColors(false).material,
        home: FTheme(
          data: const LauncherColors(false).forui,
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => PackUpdateDialog(
                    controller: controller,
                    instance: instance,
                  ),
                ),
                child: const Text('Open upgrade'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open upgrade'));
  }

  AppButton action(WidgetTester tester, String text) =>
      tester.widget<AppButton>(
        find.byWidgetPredicate(
          (widget) => widget is AppButton && widget.label == text,
        ),
      );

  Future<void> wait(WidgetTester tester, bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(ready(), true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'unrecognized imported packs show linking and file-update choices instead of a blank dialog',
    (tester) async {
      await open(tester);
      await wait(
        tester,
        () =>
            find.text('本地导入的整合包尚未关联在线项目。').evaluate().isNotEmpty &&
            action(tester, '关联并检查更新').onPressed != null,
      );
      expect(action(tester, '从文件更新').onPressed, isNotNull);
      expect(find.text('显示测试版'), findsNothing);
      expect(tester.getRect(find.byType(AlertDialog)).height, lessThan(716));
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('pack-update-project-reference')),
          matching: find.byType(EditableText),
        ),
        'https://modrinth.com/modpack/example-pack',
      );
      await tester.tap(find.text('关联并检查更新'));
      await wait(
        tester,
        () =>
            find
                .byKey(const ValueKey('pack-update-version'))
                .evaluate()
                .isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      final saved = await tester.runAsync(() => readPackRecord(instance));
      expect(saved!['projectId'], _OriginCatalog.pack.id);
      expect(saved['releaseId'], '');
      expect(saved['originReleaseId'], record['releaseId']);
      expect(catalog.versionRequests, isEmpty);
      expect(action(tester, '下载并预览').onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('pack-update-version')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2.0.0 · 1.21.1 · release').last);
      await wait(tester, () => action(tester, '下载并预览').onPressed != null);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recognized imported archives list online upgrades and keep their actual installed release',
    (tester) async {
      await tester.runAsync(cacheArchive);
      catalog.close();
      catalog = _OriginCatalog(controller.settings, identify: true);
      await open(tester);
      await wait(
        tester,
        () =>
            find
                .byKey(const ValueKey('pack-update-version'))
                .evaluate()
                .isNotEmpty &&
            action(tester, '下载并预览').onPressed != null,
      );
      final saved = await tester.runAsync(() => readPackRecord(instance));
      expect(saved!['releaseId'], 'old');
      expect(saved['version'], '1.0.0');
      expect(saved['originReleaseId'], record['releaseId']);
      expect(find.text('本地导入的整合包尚未关联在线项目。'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
