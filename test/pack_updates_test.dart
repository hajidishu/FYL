import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/pack_updates.dart';

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
