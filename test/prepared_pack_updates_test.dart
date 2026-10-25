import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/data_directory.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/pack_import.dart';
import 'package:free_your_launcher/core/pack_updates.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late String support;
  const platform = HostPlatform('windows', 'x86_64');
  LauncherController controller([String? directory]) => LauncherController(
    supportDirectory: directory ?? support,
    platform: platform,
  );
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-prepared-upgrade-');
    support = p.join(temporary.path, 'profile');
  });
  tearDown(() async => temporary.delete(recursive: true));

  Future<ContentTask> prepare(LauncherController owner) async {
    Future<void> file(String path, String contents) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(contents);
    }

    GameInstance instance(String id, String name) => GameInstance(
      id: id,
      name: name,
      root: owner.settings.gameRoot,
      version: '1.21.1',
      isolated: true,
      javaMajor: 21,
      installation: const {'modpack': true},
    );
    final original = instance('current', 'My Pack');
    final staged = instance('incoming', 'FYL-update-test');
    owner.instances.add(original);
    for (final (game, text) in [(original, 'old'), (staged, 'new')]) {
      final mod = p.join(game.gameDirectory, 'mods', 'demo.jar');
      await file(mod, text);
      await file(game.metadataPath, jsonEncode({'id': game.name}));
      await file(game.clientJarPath, 'game jar');
      await file(
        p.join(game.launcherDirectory, 'modpack.json'),
        jsonEncode({
          'version': text,
          'managedFiles': ['mods/demo.jar'],
          'fileHashes': {'mods/demo.jar': await packFileHash(mod)},
        }),
      );
    }
    final archive = File(p.join(support, 'cache', 'pack.mrpack'));
    await archive.parent.create(recursive: true);
    await archive.writeAsBytes(
      ZipEncoder().encode(
        Archive()..addFile(
          ArchiveFile.string(
            'modrinth.index.json',
            jsonEncode({
              'formatVersion': 1,
              'game': 'minecraft',
              'versionId': '2.0',
              'name': 'My Pack',
              'dependencies': {'minecraft': '1.21.1'},
              'files': [],
            }),
          ),
        ),
      ),
    );
    final task =
        ContentTask(staged.name, ContentKind.modpack, ContentSource.modrinth)
          ..preparedInstance = staged
          ..updateTargetId = original.id
          ..updateArchive = archive.path
          ..updateProject = const ContentProject(
            source: ContentSource.modrinth,
            kind: ContentKind.modpack,
            id: 'project',
            slug: 'project',
            name: 'My Pack',
            summary: '',
            author: '',
            website: '',
          )
          ..updateRelease = ContentVersion(
            source: ContentSource.modrinth,
            id: 'release',
            projectId: 'project',
            name: '2.0',
            number: '2.0',
            published: DateTime.utc(2026),
          );
    owner.content.tasks.add(task);
    // This is the installer's publication callback, before marking completion.
    await owner.content.onPreparedPackUpdate!(task);
    task.state = ContentTaskState.completed;
    return task;
  }

  for (final keepOriginal in [false, true]) {
    test(
      'prepared upgrade survives restart and commits once (copy: $keepOriginal)',
      () async {
        final first = controller();
        await first.initialize();
        final prepared = await prepare(first);
        first
            .dispose(); // No final flush should be needed to preserve readiness.

        final resumed = controller();
        await resumed.initialize();
        final task = resumed.content.tasks.single;
        expect(task.id, prepared.id);
        expect(task.state, ContentTaskState.completed);
        expect(task.updateRelease!.number, '2.0');
        expect((await inspectModpack(task.updateArchive!)).version, '2.0');
        final preview = await previewPackUpdate(
          resumed.instances.single,
          task.preparedInstance!,
        );
        expect(preview.replaced, 1);
        final updated = await resumed.applyPackUpdate(
          preview,
          {},
          task,
          keepOriginal: keepOriginal,
          copyName: 'My Pack 2.0',
        );
        expect(
          await File(
            p.join(updated.gameDirectory, 'mods', 'demo.jar'),
          ).readAsString(),
          'new',
        );
        resumed.dispose();

        final reopened = controller();
        addTearDown(reopened.dispose);
        await reopened.initialize();
        expect(reopened.content.tasks, isEmpty);
        expect(reopened.instances, hasLength(keepOriginal ? 2 : 1));
        expect(
          await Directory(prepared.preparedInstance!.versionDirectory).exists(),
          isFalse,
        );
      },
    );
  }

  test(
    'dismissing cannot orphan a prepared upgrade and cancellation persists',
    () async {
      final first = controller();
      await first.initialize();
      final prepared = await prepare(first);
      expect(first.dismissContentTask(prepared), isFalse);
      first.dispose();
      final resumed = controller();
      await resumed.initialize();
      final task = resumed.content.tasks.single;
      await resumed.discardPackUpdate(task);
      expect(resumed.dismissContentTask(task), isTrue);
      resumed.dispose();
      final reopened = controller();
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.content.tasks, isEmpty);
      expect(
        await Directory(prepared.preparedInstance!.versionDirectory).exists(),
        isFalse,
      );
    },
  );

  test(
    'prepared upgrades survive data migration and verified source cleanup',
    () async {
      final first = controller();
      await first.initialize();
      await prepare(first);
      first.dispose();
      final manager = DataDirectoryManager(
        installationDirectory: p.join(temporary.path, 'app'),
        legacyDirectory: () => null,
      );
      final destination = manager.defaultDirectory;
      await manager.select(destination, source: support, migrate: true);
      await manager.activate();
      expect(await manager.completeMigration(), isNull);
      final resumed = controller(destination);
      addTearDown(resumed.dispose);
      await resumed.initialize();
      final task = resumed.content.tasks.single;
      expect(task.preparedInstance!.root, p.join(destination, '.minecraft'));
      expect(task.updateArchive, p.join(destination, 'cache', 'pack.mrpack'));
      expect((await inspectModpack(task.updateArchive!)).version, '2.0');
      final preview = await previewPackUpdate(
        resumed.instances.single,
        task.preparedInstance!,
      );
      expect(preview.replaced, 1);
    },
  );

  test(
    'a missing archive leaves a visible task that can still be discarded',
    () async {
      final first = controller();
      await first.initialize();
      final prepared = await prepare(first);
      await File(prepared.updateArchive!).delete();
      first.dispose();
      final resumed = controller();
      addTearDown(resumed.dispose);
      await resumed.initialize();
      final task = resumed.content.tasks.single;
      expect(task.state, ContentTaskState.failed);
      expect(task.canRetry, isFalse);
      expect(task.preparedInstance, isNotNull);
      await resumed.discardPackUpdate(task);
      expect(task.preparedInstance, isNull);
      expect(
        await Directory(prepared.preparedInstance!.versionDirectory).exists(),
        isFalse,
      );
    },
  );
}
