import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/local_mods.dart';
import 'package:free_your_launcher/core/mod_updates.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/main.dart';
import 'package:path/path.dart' as p;

class UpdateUiController extends LauncherController {
  UpdateUiController({required super.supportDirectory})
    : super(platform: const HostPlatform('windows', 'x86_64'));
  final applied = <String>[];
  Completer<void>? updateGate;
  Future<void> writeMod(
    String name, {
    String version = '1',
    bool enabled = true,
  }) async {
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'fabric.mod.json',
          jsonEncode({
            'id': name.toLowerCase(),
            'name': name,
            'version': version,
            'description':
                'A Mod description that remains readable next to update controls.',
          }),
        ),
      );
    final file = File(
      p.join(
        instances.single.gameDirectory,
        'mods',
        '$name.jar${enabled ? '' : '.disabled'}',
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(ZipEncoder().encode(archive));
  }

  ContentVersion version(LocalMod mod, String v) => ContentVersion(
    source: ContentSource.modrinth,
    id: '${mod.id}-$v',
    projectId: mod.id,
    name: '${mod.name} $v',
    number: v,
    published: DateTime(2024 + int.parse(v)),
    gameVersions: ['1.21.1'],
    loaders: ['fabric'],
  );
  @override
  Future<ModUpdateCheck> checkModUpdates(
    String id,
    List<LocalMod> mods,
    CancellationToken token, {
    ModUpdateProgress? onProgress,
  }) async {
    final identified = {
      for (final mod in mods)
        mod.path: IdentifiedMod(
          mod,
          ModFingerprint(mod.path, 'fixture', 1),
          version(mod, mod.version),
        ),
    };
    return ModUpdateCheck(
      identified: identified,
      updates: {
        for (final entry in identified.entries)
          if (entry.value.mod.name != 'Beta' && entry.value.mod.version == '1')
            entry.key: ModUpdate(entry.value, version(entry.value.mod, '2')),
      },
    );
  }

  @override
  Future<void> installModUpdates(
    String id,
    List<ModUpdate> updates,
    ModUpdateCheck check, {
    ModUpdateProgress? onProgress,
  }) async {
    if (updateGate != null) await updateGate!.future;
    for (final update in updates) {
      final mod = update.installed.mod;
      applied.add(mod.name);
      await writeMod(mod.name, version: '2', enabled: mod.enabled);
    }
  }
}

void main() {
  late Directory temporary;
  late UpdateUiController controller;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-update-widgets-');
    controller = UpdateUiController(supportDirectory: temporary.path);
    controller.instances.add(
      GameInstance(
        id: 'game',
        name: 'Game',
        version: '1.21.1',
        root: temporary.path,
        isolated: true,
        javaMajor: 21,
        components: 'Fabric 0.16.10',
      ),
    );
    for (final name in ['Alpha', 'Beta', 'Gamma']) {
      await controller.writeMod(name, enabled: name != 'Gamma');
    }
  });
  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 3),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      LauncherApp(controller: controller, nativeWindow: false),
    );
    await tester.tap(find.byKey(const ValueKey('navigation-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('instance-settings-game')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('instance-tab-2')));
    await settle(tester);
  }

  for (final size in [const Size(800, 600), const Size(1180, 780)]) {
    testWidgets(
      'selecting available updates ignores search filters and updates only those files at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await open(tester);
        await tester.enterText(find.byType(EditableText).first, 'Alpha');
        await tester.tap(find.byKey(const ValueKey('select-updatable-mods')));
        await settle(tester);
        expect(find.text('已选择 2 项'), findsOneWidget);
        expect(
          tester.widget<Checkbox>(find.byType(Checkbox).first).value,
          isTrue,
        );
        expect(find.text('发现 2 个可更新 Mod'), findsOneWidget);
        expect(find.text('更新所选(2)'), findsOneWidget);
        expect(find.text('1 → 2'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('update-selected-mods')));
        await settle(tester);
        expect(controller.applied, ['Alpha', 'Gamma']);
        expect(
          await tester.runAsync(
            () => File(
              p.join(
                controller.instances.single.gameDirectory,
                'mods',
                'Gamma.jar.disabled',
              ),
            ).exists(),
          ),
          isTrue,
        );
        expect(find.text('已更新 2 个 Mod。'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('a row update checks and updates a single Mod', (tester) async {
    await open(tester);
    final alpha = p.join(
      controller.instances.single.gameDirectory,
      'mods',
      'Alpha.jar',
    );
    final button = find.byKey(ValueKey('update-mod-$alpha'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await settle(tester);
    expect(controller.applied, ['Alpha']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('an update may finish safely after navigating away', (
    tester,
  ) async {
    controller.updateGate = Completer<void>();
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('select-updatable-mods')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('update-selected-mods')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.updateGate!.complete();
    await settle(tester);
    expect(controller.applied, ['Alpha', 'Gamma']);
    expect(tester.takeException(), isNull);
  });
}
