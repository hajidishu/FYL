import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/content_installer.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/local_pack.dart';
import 'package:free_your_launcher/core/minecraft.dart' show versionManifestUrl;
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/ui/community_page.dart';
import 'package:free_your_launcher/ui/file_drop.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:path/path.dart' as p;

class LocalPackNetwork extends OfficialNetwork {
  LocalPackNetwork(super.settings);
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
    throw StateError('Unexpected network request');
  }
}

class DropTestController extends LauncherController {
  DropTestController({
    required super.supportDirectory,
    required super.platform,
  });
  @override
  ContentInstaller get content => _content;
  late final _content = ContentInstaller(
    platform: platform,
    supportDirectory: supportDirectory,
    settings: () => settings.copy(),
    onChanged: notifyListeners,
    busy: () => installing,
    catalogFactory: (settings) =>
        CommunityCatalog(settings, network: LocalPackNetwork(settings)),
    installBase: (task, token, update) async => GameInstance(
      id: 'imported-${task.instanceName}',
      name: task.instanceName,
      version: task.version.id,
      root: task.settings.gameRoot,
      isolated: task.settings.isolateVersions,
      javaMajor: 21,
    ),
    onInstalled: (instance) async {
      instances.add(instance);
      selectedId = instance.id;
    },
  );
}

void main() {
  late Directory temporary;
  late DropTestController controller;
  late String modPath, packPath;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-drop-');
    controller = DropTestController(
      supportDirectory: temporary.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    for (final id in ['first', 'second']) {
      controller.instances.add(
        GameInstance(
          id: id,
          name: id,
          version: '1.21.1',
          root: controller.settings.gameRoot,
          isolated: true,
          javaMajor: 21,
          components: 'Fabric 0.16.10',
        ),
      );
    }
    controller.selectedId = 'second';
    modPath = p.join(temporary.path, 'example.jar');
    await File(modPath).writeAsBytes(
      ZipEncoder().encode(
        Archive()..addFile(
          ArchiveFile.string('fabric.mod.json', '{"id":"test","version":"1"}'),
        ),
      ),
    );
    packPath = p.join(temporary.path, 'example.mrpack');
    await File(packPath).writeAsBytes(
      ZipEncoder().encode(
        Archive()
          ..addFile(
            ArchiveFile.string(
              'modrinth.index.json',
              jsonEncode({
                'formatVersion': 1,
                'game': 'minecraft',
                'name': 'Dropped Pack',
                'versionId': '1',
                'dependencies': {'minecraft': '1.21.1'},
                'files': [],
              }),
            ),
          )
          ..addFile(
            ArchiveFile.string('overrides/options.txt', 'pack-options'),
          ),
      ),
    );
  });
  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });
  Widget harness(GlobalKey<FileDropRegionState> key) => MaterialApp(
    theme: const LauncherColors(false).material,
    home: FTheme(
      data: const LauncherColors(false).forui,
      child: Scaffold(
        body: FileDropRegion(
          key: key,
          controller: controller,
          onTaskStarted: () {},
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );

  Future<Future<void> Function()> begin(
    WidgetTester tester,
    GlobalKey<FileDropRegionState> key,
    List<String> paths,
    Finder dialog,
  ) async {
    late Future<void> pending;
    await tester.runAsync(() async {
      pending = key.currentState!.handlePaths(paths);
    });
    final watch = Stopwatch()..start();
    while (dialog.evaluate().isEmpty &&
        watch.elapsed < const Duration(seconds: 5)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget, reason: controller.errorMessage);
    return () => pending;
  }

  test(
    'local pack snapshots remain readable after the original file is removed',
    () async {
      final (plan, project, release) = await stageLocalPack(
        packPath,
        controller.supportDirectory,
      );
      expect(
        p.isWithin(p.join(controller.supportDirectory, 'cache'), plan.archive),
        isTrue,
      );
      await File(packPath).delete();
      expect(await File(plan.archive).exists(), isTrue);
      expect(plan.name, 'Dropped Pack');
      expect(project.id, release.projectId);
    },
  );
  testWidgets(
    'dropped mods default to the selected game and install only after confirmation',
    (tester) async {
      final key = GlobalKey<FileDropRegionState>();
      await tester.pumpWidget(harness(key));
      await tester.pumpAndSettle();
      final finish = await begin(tester, key, [
        modPath,
      ], find.byType(ModImportDialog));
      expect(
        tester.widget<SelectBox<String>>(find.byType(SelectBox<String>)).value,
        'second',
      );
      final target = File(
        p.join(controller.instances.last.gameDirectory, 'mods', 'example.jar'),
      );
      expect(await tester.runAsync(target.exists), isFalse);
      await tester.tap(find.byKey(const ValueKey('confirm-dropped-mods')));
      await tester.pumpAndSettle();
      await tester.runAsync(finish);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(target.exists), isTrue);
      expect(
        await tester.runAsync(
          () => File(
            p.join(
              controller.instances.first.gameDirectory,
              'mods',
              'example.jar',
            ),
          ).exists(),
        ),
        isFalse,
      );
      expect(controller.errorMessage, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('cancelling a dropped mod leaves game files unchanged', (
    tester,
  ) async {
    final key = GlobalKey<FileDropRegionState>();
    await tester.pumpWidget(harness(key));
    await tester.pumpAndSettle();
    final finish = await begin(tester, key, [
      modPath,
    ], find.byType(ModImportDialog));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.runAsync(finish);
    expect(
      await tester.runAsync(
        () => Directory(
          p.join(controller.instances.last.gameDirectory, 'mods'),
        ).exists(),
      ),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'dropped mods can target a different version without switching the launch selection',
    (tester) async {
      final key = GlobalKey<FileDropRegionState>();
      await tester.pumpWidget(harness(key));
      await tester.pumpAndSettle();
      final finish = await begin(tester, key, [
        modPath,
      ], find.byType(ModImportDialog));
      await tester.tap(find.byType(SelectBox<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('first · 1.21.1').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('confirm-dropped-mods')));
      await tester.pumpAndSettle();
      await tester.runAsync(finish);
      await tester.pumpAndSettle();
      expect(controller.selectedId, 'second');
      expect(
        await tester.runAsync(
          () => File(
            p.join(
              controller.instances.first.gameDirectory,
              'mods',
              'example.jar',
            ),
          ).exists(),
        ),
        isTrue,
      );
      expect(controller.errorMessage, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'vanilla remains the default selection but requires a loader before importing mods',
    (tester) async {
      controller.instances.add(
        GameInstance(
          id: 'vanilla',
          name: 'Vanilla',
          version: '1.21.1',
          root: controller.settings.gameRoot,
          isolated: true,
          javaMajor: 21,
        ),
      );
      controller.selectedId = 'vanilla';
      final key = GlobalKey<FileDropRegionState>();
      await tester.pumpWidget(harness(key));
      await tester.pumpAndSettle();
      final finish = await begin(tester, key, [
        modPath,
      ], find.byType(ModImportDialog));
      expect(
        tester.widget<SelectBox<String>>(find.byType(SelectBox<String>)).value,
        'vanilla',
      );
      expect(
        tester
            .widget<AppButton>(
              find.byKey(const ValueKey('confirm-dropped-mods')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.runAsync(finish);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'dropped packs show editable options before creating or installing a version',
    (tester) async {
      final key = GlobalKey<FileDropRegionState>();
      await tester.pumpWidget(harness(key));
      await tester.pumpAndSettle();
      final finish = await begin(tester, key, [
        packPath,
      ], find.byType(PackInstallDialog));
      expect(controller.content.tasks, isEmpty);
      expect(controller.instances, hasLength(2));
      await tester.enterText(
        find
            .byWidgetPredicate(
              (widget) => widget is EditableText && !widget.readOnly,
            )
            .first,
        'Imported Pack',
      );
      await tester.ensureVisible(find.text('开始安装'));
      await tester.tap(find.text('开始安装'));
      await tester.pumpAndSettle();
      await tester.runAsync(finish);
      await tester.pumpAndSettle();
      expect(controller.errorMessage, isNull);
      expect(controller.instances.last.name, 'Imported Pack');
      expect(
        await tester.runAsync(
          () => File(
            p.join(controller.instances.last.gameDirectory, 'options.txt'),
          ).readAsString(),
        ),
        'pack-options\nlang:zh_cn\n',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'unsupported drops report a clear error without starting an install',
    (tester) async {
      final key = GlobalKey<FileDropRegionState>();
      await tester.pumpWidget(harness(key));
      await tester.pumpAndSettle();
      final file = File(p.join(temporary.path, 'unrelated.txt'));
      await tester.runAsync(() => file.writeAsString('unrelated'));
      await tester.runAsync(() => key.currentState!.handlePaths([file.path]));
      await tester.pumpAndSettle();
      expect(controller.errorMessage, contains('支持拖入 JAR'));
      expect(controller.content.tasks, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
