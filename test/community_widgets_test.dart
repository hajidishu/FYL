import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/account_store.dart';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/install_options.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/pack_import.dart';
import 'package:free_your_launcher/ui/community_page.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:path/path.dart' as p;

class MemorySecrets extends SecureAccountTokenStore {
  final values = <String, String>{};
  @override
  Future<String?> readValue(String id) async => values[id];
  @override
  Future<void> writeValue(String id, String value) async {
    values[id] = value;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }
}

class WidgetCatalog extends CommunityCatalog {
  WidgetCatalog(super.settings);
  static const example = ContentProject(
    source: ContentSource.modrinth,
    kind: ContentKind.mod,
    id: 'demo',
    slug: 'demo',
    name: 'Example Mod',
    summary: 'A compatible mod',
    author: 'Author',
    website: 'https://modrinth.com/mod/demo',
    loaders: ['fabric'],
    gameVersions: ['1.21.1'],
  );
  static ContentVersion get release => ContentVersion(
    source: ContentSource.modrinth,
    id: 'release-1',
    projectId: 'demo',
    name: 'Release 1.0',
    number: '1.0',
    published: DateTime(2024),
    gameVersions: ['1.21.1'],
    loaders: ['fabric'],
    files: [
      const ContentFile(
        name: 'demo.jar',
        urls: ['https://cdn.modrinth.com/demo.jar'],
      ),
    ],
  );
  @override
  Future<ContentSearchResult> search({
    required ContentKind kind,
    String query = '',
    String minecraft = '',
    String? loader,
    ContentSource? source,
    int page = 0,
    bool newest = false,
    CancellationToken? token,
  }) async => const ContentSearchResult([example]);
  @override
  Future<ContentVersionPage> versions(
    ContentProject project,
    CancellationToken token, {
    String minecraft = '',
    String? loader,
    int page = 0,
  }) async => ContentVersionPage([release]);
  @override
  Future<String> description(
    ContentProject project,
    CancellationToken token,
  ) async => 'Project description';
}

void main() {
  late Directory temporary;
  late LauncherController controller;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-community-ui-');
    controller = LauncherController(
      supportDirectory: temporary.path,
      platform: const HostPlatform('windows', 'x86_64'),
      appSecrets: MemorySecrets(),
    );
    await controller.initialize();
    controller.instances.add(
      GameInstance(
        id: 'target',
        name: 'Fabric Game',
        version: '1.21.1',
        root: temporary.path,
        isolated: true,
        javaMajor: 21,
        components: 'Fabric 0.16.10',
      ),
    );
  });
  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });
  Widget harness(Widget child) => MaterialApp(
    theme: const LauncherColors(false).material,
    home: FTheme(
      data: const LauncherColors(false).forui,
      child: Scaffold(body: child),
    ),
  );

  test(
    'CurseForge secret persists outside ordinary configuration and can be cleared',
    () async {
      final secretStore = MemorySecrets();
      final active = LauncherController(
        supportDirectory: temporary.path,
        platform: controller.platform,
        appSecrets: secretStore,
      );
      addTearDown(active.dispose);
      await active.initialize();
      await active.saveSettings(
        active.settings.copy()..curseforgeApiKey = 'private-key-for-test',
      );
      final raw = await File(
        p.join(temporary.path, 'launcher.json'),
      ).readAsString();
      expect(raw, isNot(contains('private-key-for-test')));
      expect(jsonDecode(raw)['hasCurseforgeApiKey'], isTrue);
      final restored = LauncherController(
        supportDirectory: temporary.path,
        platform: controller.platform,
        appSecrets: secretStore,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.settings.curseforgeApiKey, 'private-key-for-test');
      await restored.saveSettings(
        restored.settings.copy()..curseforgeApiKey = '',
      );
      expect(secretStore.values, isEmpty);
    },
  );

  for (final size in [const Size(800, 600), const Size(1180, 780)]) {
    testWidgets(
      'community search, version choice and save dialog defaults fit $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final asked = Completer<(String, String)>();
        await tester.pumpWidget(
          harness(
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                height: size.height - 220,
                child: CommunityPage(
                  controller: controller,
                  kind: ContentKind.mod,
                  catalog: WidgetCatalog(controller.settings),
                  onTaskStarted: () {},
                  onOpenSettings: () {},
                  savePicker: (directory, name) async {
                    asked.complete((directory, name));
                    return null;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Example Mod'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Example Mod'));
        await tester.pumpAndSettle();
        expect(find.text('Release 1.0'), findsOneWidget);
        final action = find.byKey(const ValueKey('install-content-release-1'));
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        expect(tester.widget<AppButton>(action).onPressed, isNotNull);
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(asked.isCompleted, isTrue);
        final args = await asked.future;
        expect(
          args.$1,
          p.join(controller.instances.single.gameDirectory, 'mods'),
        );
        expect(args.$2, 'demo.jar');
        expect(
          controller.content.tasks,
          isEmpty,
          reason: 'Cancelling the native save dialog must not start a download',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'pack preview shows pinned information and returns explicit install choices',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      PackChoices? result;
      final plan = PackPlan(
        archive: 'unused',
        name: 'Example Pack',
        version: '2',
        minecraft: '1.21.1',
        source: ContentSource.modrinth,
        loader: ModLoader.fabric,
        loaderVersion: '0.16.10',
        files: [const PackEntry('mods/optional.jar', optional: true)],
        overrides: {},
      );
      await tester.pumpWidget(
        harness(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<PackChoices>(
                  context: context,
                  builder: (_) => PackInstallDialog(
                    plan: plan,
                    release: WidgetCatalog.release,
                    isolated: true,
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Minecraft：1.21.1'), findsOneWidget);
      await tester.enterText(find.byType(EditableText).first, 'My Pack');
      await tester.ensureVisible(find.text('mods/optional.jar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('mods/optional.jar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始安装'));
      await tester.pumpAndSettle();
      expect(result!.name, 'My Pack');
      expect(result!.isolated, isTrue);
      expect(result!.optional, contains('mods/optional.jar'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
