import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/pack_updates.dart';
import 'package:free_your_launcher/core/pack_origin.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';

void main() {
  late Directory root;
  late GameInstance original, staged;
  Future<void> file(GameInstance instance, String path, String text) async {
    final target = File(p.join(instance.gameDirectory, path));
    await target.parent.create(recursive: true);
    await target.writeAsString(text);
  }

  Future<void> record(
    GameInstance instance,
    Map<String, String> contents, {
    bool legacy = false,
  }) async {
    for (final entry in contents.entries) {
      await file(instance, entry.key, entry.value);
    }
    final hashes = await hashPackFiles({
      for (final path in contents.keys)
        path: p.join(instance.gameDirectory, path),
    });
    await file(
      instance,
      '.fyl/modpack.json',
      jsonEncode({
        'managedFiles': contents.keys.toList(),
        if (!legacy) 'fileHashes': hashes,
      }),
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fyl-pack-update-');
    GameInstance instance(String name) => GameInstance(
      id: name,
      name: name,
      root: root.path,
      version: '1.21.1',
      isolated: true,
      javaMajor: 21,
    );
    original = instance('original');
    staged = instance('FYL-update-test');
  });
  tearDown(() async => root.delete(recursive: true));

  test(
    'restoring after a version rename preserves its current name and the immutable backup',
    () async {
      final controller = LauncherController(
        supportDirectory: p.join(root.path, 'support'),
        platform: const HostPlatform('windows', 'x86_64'),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await file(
        original,
        '${original.name}.json',
        jsonEncode({'id': original.name}),
      );
      await file(original, '${original.name}.jar', 'new jar');
      final backupRoot = p.join(original.root, '.fyl', 'pack-backups', 'test');
      final backup = Directory(p.join(backupRoot, 'version'));
      await backup.create(recursive: true);
      final previous = GameInstance.fromJson({
        ...original.toJson(),
        'version': '1.20.1',
        'icon': p.join(original.versionDirectory, 'cover.png'),
      });
      final snapshot = jsonEncode(previous.toJson());
      await File(p.join(backupRoot, 'instance.json')).writeAsString(snapshot);
      await File(
        p.join(backup.path, '${original.name}.json'),
      ).writeAsString(jsonEncode({'id': original.name}));
      await File(
        p.join(backup.path, '${original.name}.jar'),
      ).writeAsString('old jar');
      controller.instances.add(
        GameInstance.fromJson({
          ...original.toJson(),
          'installation': {'packBackup': backupRoot},
        }),
      );
      await controller.saveInstance(
        controller.instances.single.copyWith(name: 'Renamed Pack'),
      );
      await controller.restorePackBackup(original.id);
      final restored = controller.instances.single;
      expect(restored.name, 'Renamed Pack');
      expect(restored.version, '1.20.1');
      expect(restored.icon, p.join(restored.versionDirectory, 'cover.png'));
      expect(await File(restored.clientJarPath).readAsString(), 'old jar');
      expect(
        (jsonDecode(await File(restored.metadataPath).readAsString())
            as Json)['id'],
        restored.name,
      );
      expect(
        await File(p.join(backupRoot, 'instance.json')).readAsString(),
        snapshot,
      );
      expect(
        await File(p.join(backup.path, '${original.name}.jar')).readAsString(),
        'old jar',
      );
      expect(
        await File(
          p.join('$backupRoot.reverted', '${restored.name}.jar'),
        ).readAsString(),
        'new jar',
      );
      expect(
        await Directory(p.join(backupRoot, 'restore-prepared')).exists(),
        isFalse,
      );
    },
  );

  test(
    'author updates and removals preserve personal and unmanaged files',
    () async {
      await record(original, {
        'mods/old.jar': 'old',
        'config/default.cfg': 'a',
      });
      await file(original, 'saves/world/level.dat', 'my world');
      await file(original, 'mods/custom.jar', 'custom');
      await record(staged, {
        'mods/new.jar': 'new',
        'config/default.cfg': 'b',
        'saves/world/level.dat': 'bundled world',
      });
      final preview = await previewPackUpdate(original, staged);
      expect(preview.deleted, 1);
      expect(preview.replaced, 1);
      expect(preview.conflicts, isEmpty);
      await mergePackUpdate(preview, {}, CancellationToken());
      expect(
        await File(p.join(staged.gameDirectory, 'mods/old.jar')).exists(),
        false,
      );
      expect(
        await File(
          p.join(staged.gameDirectory, 'mods/custom.jar'),
        ).readAsString(),
        'custom',
      );
      expect(
        await File(
          p.join(staged.gameDirectory, 'saves/world/level.dat'),
        ).readAsString(),
        'my world',
      );
      expect(
        await File(
          p.join(original.gameDirectory, 'mods/old.jar'),
        ).readAsString(),
        'old',
      );
    },
  );

  test(
    'both modified config versions require an explicit conflict choice',
    () async {
      await record(original, {'config/mod.toml': 'baseline'});
      await file(original, 'config/mod.toml', 'user changes');
      await record(staged, {'config/mod.toml': 'new author defaults'});
      final preview = await previewPackUpdate(original, staged);
      expect(preview.conflicts, {'config/mod.toml'});
      await mergePackUpdate(preview, {}, CancellationToken());
      expect(
        await File(
          p.join(staged.gameDirectory, 'config/mod.toml'),
        ).readAsString(),
        'user changes',
      );
      expect((await readPackRecord(staged))['fileHashes'], preview.incoming);
    },
  );

  test('legacy records are treated conservatively', () async {
    await record(original, {
      'config/mod.cfg': 'unknown original',
    }, legacy: true);
    await record(staged, {'config/mod.cfg': 'new'});
    expect((await previewPackUpdate(original, staged)).conflicts, {
      'config/mod.cfg',
    });
  });

  test(
    'legacy author baselines can be rebuilt from the original install cache',
    () async {
      await record(original, {
        'mods/old.jar': 'original author file',
      }, legacy: true);
      await record(staged, {'mods/new.jar': 'new author file'});
      final metadata = await readPackRecord(original);
      metadata.addAll({'source': 'modrinth', 'releaseId': 'old-release'});
      await file(original, '.fyl/modpack.json', jsonEncode(metadata));
      final support = p.join(root.path, 'support');
      final cacheKey = sha256
          .convert(utf8.encode('pack-files:modrinth:old-release'))
          .toString();
      final cached = File(
        p.join(
          support,
          'cache',
          'community',
          cacheKey,
          'files',
          'mods',
          'old.jar',
        ),
      );
      await cached.parent.create(recursive: true);
      await cached.writeAsString('original author file');
      final preview = await previewPackUpdate(
        original,
        staged,
        supportDirectory: support,
      );
      expect(preview.deleted, 1);
      expect(preview.conflicts, isEmpty);
      expect(preview.unknownBaseline, false);
      final linked = linkedPackRecord(
        metadata,
        const ContentProject(
          source: ContentSource.curseforge,
          kind: ContentKind.modpack,
          id: '123',
          slug: 'linked-pack',
          name: 'Linked Pack',
          summary: '',
          author: '',
          website: '',
        ),
      );
      await file(original, '.fyl/modpack.json', jsonEncode(linked));
      final relinked = await previewPackUpdate(
        original,
        staged,
        supportDirectory: support,
      );
      expect(relinked.deleted, 1);
      expect(relinked.conflicts, isEmpty);
      expect(relinked.unknownBaseline, false);
      await file(original, 'mods/old.jar', 'user modified the jar');
      expect(
        (await previewPackUpdate(
          original,
          staged,
          supportDirectory: support,
        )).conflicts,
        contains('mods/old.jar'),
      );
    },
  );

  test(
    'Windows path casing does not turn author updates into duplicate files',
    () async {
      await record(original, {'Config/mod.toml': 'old default'});
      await record(staged, {'config/mod.toml': 'new default'});
      final preview = await previewPackUpdate(original, staged);
      expect(preview.conflicts, isEmpty);
      expect(preview.replaced, 1);
    },
    skip: !Platform.isWindows,
  );

  test('files changed after preview abort before modifying original', () async {
    await record(original, {'mods/a.jar': 'old'});
    await record(staged, {'mods/a.jar': 'new'});
    final preview = await previewPackUpdate(original, staged);
    await file(original, 'mods/a.jar', 'external edit');
    await expectLater(
      mergePackUpdate(preview, {}, CancellationToken()),
      throwsStateError,
    );
    expect(
      await File(p.join(original.gameDirectory, 'mods/a.jar')).readAsString(),
      'external edit',
    );
  });

  test('interrupted publication restores archived version', () async {
    await record(original, {'mods/a.jar': 'old'});
    final backup = p.join(root.path, '.fyl', 'pack-backups', 'test', 'version');
    await Directory(p.dirname(backup)).create(recursive: true);
    await writePackUpdateJournal(root.path, {
      'original': original.toJson(),
      'updated': {
        ...original.toJson(),
        'installation': {'packBackup': p.dirname(backup)},
      },
      'backup': backup,
    });
    await Directory(original.versionDirectory).rename(backup);
    await file(original, 'mods/a.jar', 'partial new');
    await recoverPackUpdate(root.path, [original]);
    expect(
      await File(p.join(original.gameDirectory, 'mods/a.jar')).readAsString(),
      'old',
    );
    expect(await Directory('$backup.interrupted').exists(), true);
  });
}
