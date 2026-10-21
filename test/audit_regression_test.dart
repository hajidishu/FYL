import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/pack_import.dart';
import 'package:free_your_launcher/ui/community_page.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:path/path.dart' as p;

class RunningProcessStub implements Process {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class AuditCatalog extends CommunityCatalog {
  AuditCatalog(super.settings);
  static const example = ContentProject(
    source: ContentSource.modrinth,
    kind: ContentKind.mod,
    id: 'test',
    slug: 'test',
    name: 'Test Mod',
    summary: '',
    author: '',
    website: '',
  );
  static final release = ContentVersion(
    source: ContentSource.modrinth,
    id: 'release',
    projectId: 'test',
    name: 'Test release',
    number: '1',
    published: DateTime(2024),
    gameVersions: ['1.21.1'],
    loaders: ['fabric'],
    files: [
      const ContentFile(
        name: 'test.jar',
        urls: ['https://cdn.modrinth.com/test.jar'],
      ),
    ],
  );
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
  ) async => '';
}

void main() {
  late Directory directory;
  late LauncherController controller;
  late GameInstance target;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-audit-');
    controller = LauncherController(
      supportDirectory: directory.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    target = GameInstance(
      id: 'target',
      name: 'Target',
      version: '1.21.1',
      root: controller.settings.gameRoot,
      isolated: false,
      javaMajor: 21,
      components: 'Fabric 0.16.10',
    );
    controller.instances.add(target);
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });
  PackPlan plan() => const PackPlan(
    archive: 'unused',
    name: 'Pack',
    version: '1',
    minecraft: '1.21.1',
    source: ContentSource.modrinth,
    files: [],
    overrides: {},
  );
  const packProject = ContentProject(
    source: ContentSource.modrinth,
    kind: ContentKind.modpack,
    id: 'pack',
    slug: 'pack',
    name: 'Pack',
    summary: '',
    author: '',
    website: '',
  );

  test(
    'status distinguishes installation, launch preparation and file operations',
    () {
      expect(controller.activityText, '准备就绪');
      final task = ContentTask('Mod', ContentKind.mod, ContentSource.modrinth);
      controller.content.tasks.add(task);
      expect(controller.activityText, '正在下载社区资源');
      task.state = ContentTaskState.completed;
      controller.instanceOperation = '导出整合包';
      expect(controller.activityText, '正在导出整合包');
      controller.instanceOperation = null;
      controller.preparingLaunch = true;
      expect(controller.activityText, '正在准备启动');
    },
  );
  test(
    'closing cancels community work and waits until its rollback finishes',
    () async {
      final task = ContentTask('Mod', ContentKind.mod, ContentSource.modrinth);
      controller.content.tasks.add(task);
      var ended = false;
      final stop = controller.stopActiveTasks().then((_) => ended = true);
      expect(task.token.cancelled, isTrue);
      expect(ended, isFalse);
      task.state = ContentTaskState.cancelled;
      controller.notifyListeners();
      await stop;
      expect(ended, isTrue);
    },
  );
  test(
    'version settings cannot overwrite a directory operation in progress',
    () async {
      controller.instanceOperation = '切换游戏目录';
      await expectLater(
        controller.saveInstance(target.copyWith(favorite: true)),
        throwsStateError,
      );
      expect(controller.instances.single.favorite, isFalse);
    },
  );
  test(
    'pack names and existing directories fail before any task is started',
    () async {
      var started = 0;
      Future<void> install(String name) async {
        await controller.content.installPack(
          packProject,
          AuditCatalog.release,
          plan(),
          name,
          isolated: true,
          onStarted: (_) => started++,
        );
      }

      await expectLater(install('../escape'), throwsArgumentError);
      await expectLater(
        install('Target'),
        throwsStateError,
        reason:
            'Registered versions remain reserved even when their folder is missing',
      );
      await Directory(
        p.join(controller.settings.gameRoot, 'versions', 'Existing'),
      ).create(recursive: true);
      await expectLater(install('Existing'), throwsStateError);
      expect(started, 0);
      expect(controller.content.tasks, isEmpty);
    },
  );
  test(
    'community installation cannot modify a directory used by a different running shared version',
    () async {
      final running = target.copyWith(name: 'Running');
      controller.instances.add(
        GameInstance(
          id: 'running',
          name: running.name,
          version: running.version,
          root: running.root,
          isolated: false,
          javaMajor: 21,
        ),
      );
      controller.runningGames.add(
        RunningGame(
          process: RunningProcessStub(),
          instance: controller.instances.last,
          logPath: '',
        ),
      );
      await expectLater(
        controller.content.installMod(
          AuditCatalog.example,
          AuditCatalog.release,
          target,
          p.join(target.gameDirectory, 'mods', 'test.jar'),
        ),
        throwsStateError,
      );
      await expectLater(
        controller.content.installPack(
          packProject,
          AuditCatalog.release,
          plan(),
          'New Pack',
          isolated: false,
        ),
        throwsStateError,
      );
      expect(controller.content.tasks, isEmpty);
      controller.runningGames.clear();
    },
  );
  testWidgets(
    'an error before task creation remains visible instead of navigating away',
    (tester) async {
      var started = 0;
      final catalog = AuditCatalog(controller.settings);
      addTearDown(catalog.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: const LauncherColors(false).material,
          home: FTheme(
            data: const LauncherColors(false).forui,
            child: Scaffold(
              body: ContentDetails(
                controller: controller,
                catalog: catalog,
                project: AuditCatalog.example,
                target: target,
                initialMinecraft: '1.21.1',
                initialLoader: 'fabric',
                onBack: () {},
                onTaskStarted: () => started++,
                savePicker: (folder, name) async {
                  controller.instanceOperation = '导出整合包';
                  return p.join(folder, name);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final install = find.byKey(const ValueKey('install-content-release'));
      await tester.ensureVisible(install);
      await tester.pumpAndSettle();
      await tester.tap(install);
      await tester.pumpAndSettle();
      expect(started, 0);
      expect(find.textContaining('请等待当前'), findsOneWidget);
      expect(controller.content.tasks, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
