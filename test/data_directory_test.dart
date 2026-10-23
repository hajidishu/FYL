import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/account_store.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/data_directory.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late DataDirectoryManager manager;
  late String source, target;
  const platform = HostPlatform('windows', 'x86_64');
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-data-directory-');
    manager = DataDirectoryManager(
      installationDirectory: p.join(temporary.path, 'launcher'),
    );
    source = p.join(temporary.path, 'old-data');
    target = manager.defaultDirectory;
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<void> createSource() async {
    final controller = LauncherController(
      supportDirectory: source,
      platform: platform,
    );
    try {
      await controller.initialize();
      await controller.addOfflineAccount('Portable_User');
      controller.settings.backgroundPath = p.join(
        source,
        'appearance',
        'backgrounds',
        'image.png',
      );
      controller.instances.add(
        GameInstance(
          id: 'game',
          name: 'Portable Game',
          version: '1.21.1',
          root: controller.settings.gameRoot,
          isolated: true,
          javaMajor: 21,
          managedJava: p.join(source, '.minecraft', 'runtime', 'bin', 'java'),
          icon: p.join(source, 'icons', 'game.png'),
        ),
      );
      controller.instances.add(
        GameInstance(
          id: 'external',
          name: 'External Game',
          version: '1.21.1',
          root: p.join(temporary.path, 'external-games'),
          isolated: true,
          javaMajor: 21,
        ),
      );
      await controller.flush();
      final save = File(
        p.join(
          source,
          '.minecraft',
          'versions',
          'Portable Game',
          'saves',
          'world',
          'level.dat',
        ),
      );
      await save.parent.create(recursive: true);
      await save.writeAsBytes([1, 2, 3, 255]);
      final background = File(controller.settings.backgroundPath!);
      await background.parent.create(recursive: true);
      await background.writeAsBytes([10, 20, 30]);
    } finally {
      controller.dispose();
    }
  }

  test(
    'install directory is independent of cwd and outside the macOS bundle',
    () {
      expect(
        launcherInstallationDirectory(
          executable: r'D:\Apps\FYL\FYL.exe',
          os: 'windows',
        ),
        r'D:\Apps\FYL',
      );
      expect(
        launcherInstallationDirectory(
          executable: '/opt/FYL/free_your_launcher',
          os: 'linux',
        ),
        '/opt/FYL',
      );
      expect(
        launcherInstallationDirectory(
          executable: '/Applications/FYL.app/Contents/MacOS/free_your_launcher',
          os: 'macos',
        ),
        '/Applications',
      );
    },
  );

  test(
    'fresh install defaults to its own folder and stores only a relative bootstrap path',
    () async {
      expect((await manager.read()).directory, target);
      await manager.activate();
      await manager.completeMigration();
      final bootstrap =
          jsonDecode(await manager.configuration.readAsString()) as Json;
      expect(bootstrap['dataDirectory'], 'FYL-data');
      expect((await manager.read()).migrateFrom, isNull);
      expect(await Directory(target).exists(), isTrue);
    },
  );

  test(
    'migration preserves games, account identity and external paths then cleans the verified source',
    () async {
      await createSource();
      final progress = <DataMigrationProgress>[];
      await manager.select(target, source: source, migrate: true);
      expect(await manager.activate(onProgress: progress.add), target);
      final loaded = LauncherController(
        supportDirectory: target,
        platform: platform,
      );
      addTearDown(loaded.dispose);
      await loaded.initialize();
      expect(loaded.activeAccount!.username, 'Portable_User');
      expect(loaded.settings.gameRoot, p.join(target, '.minecraft'));
      expect(
        loaded.settings.backgroundPath,
        p.join(target, 'appearance', 'backgrounds', 'image.png'),
      );
      expect(
        loaded.instances.first.managedJava,
        p.join(target, '.minecraft', 'runtime', 'bin', 'java'),
      );
      expect(loaded.instances.first.icon, p.join(target, 'icons', 'game.png'));
      expect(
        loaded.instances.last.root,
        p.join(temporary.path, 'external-games'),
      );
      expect(
        await File(
          p.join(
            loaded.instances.first.gameDirectory,
            'saves',
            'world',
            'level.dat',
          ),
        ).readAsBytes(),
        [1, 2, 3, 255],
      );
      expect(progress.last.bytes, progress.last.totalBytes);
      expect(progress.last.files, progress.last.totalFiles);
      expect(await Directory(source).exists(), isTrue);
      expect(await manager.completeMigration(), isNull);
      expect(await Directory(source).exists(), isFalse);
      expect((await manager.read()).migrateFrom, isNull);
      final backup =
          jsonDecode(
                await File('${manager.configuration.path}.bak').readAsString(),
              )
              as Json;
      expect(backup.containsKey('migrateFrom'), isFalse);
    },
  );

  test(
    'Windows DPAPI secrets remain encrypted and readable after migration',
    () async {
      await createSource();
      final store = SecureAccountTokenStore(supportDirectory: source);
      final tokens = AccountTokens(
        refreshToken: 'migration-fixture-refresh',
        accessToken: 'migration-fixture-access',
        expiresAt: DateTime.utc(2030),
        clientId: LauncherSettings.defaultMicrosoftClientId,
      );
      await store.write('microsoft:fixture', tokens);
      await store.writeValue(
        'settings.curseforge-api-key',
        'migration-fixture-key',
      );
      await manager.select(target, source: source, migrate: true);
      await manager.activate();
      final moved = SecureAccountTokenStore(supportDirectory: target);
      expect(
        (await moved.read('microsoft:fixture'))!.refreshToken,
        tokens.refreshToken,
      );
      expect(
        await moved.readValue('settings.curseforge-api-key'),
        'migration-fixture-key',
      );
      final bytes = await Directory(p.join(target, 'credentials'))
          .list()
          .where((entry) => entry.path.endsWith('.dpapi'))
          .cast<File>()
          .first;
      expect(
        utf8.decode(await bytes.readAsBytes(), allowMalformed: true),
        isNot(contains('migration-fixture')),
      );
      expect(await manager.completeMigration(), isNull);
    },
    skip: !Platform.isWindows,
  );

  test(
    'switching without migration loads the selected profile and leaves the source intact',
    () async {
      await createSource();
      final other = LauncherController(
        supportDirectory: target,
        platform: platform,
      );
      await other.addOfflineAccount('Other_User');
      other.dispose();
      await manager.select(target, source: source, migrate: false);
      await manager.activate();
      final loaded = LauncherController(
        supportDirectory: target,
        platform: platform,
      );
      addTearDown(loaded.dispose);
      await loaded.initialize();
      expect(loaded.accounts.single.username, 'Other_User');
      await manager.completeMigration();
      expect(await Directory(source).exists(), isTrue);
      expect(
        await File(
          p.join(
            target,
            '.minecraft',
            'versions',
            'Portable Game',
            'saves',
            'world',
            'level.dat',
          ),
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'migration refuses occupied and overlapping destinations without overwriting them',
    () async {
      await createSource();
      await Directory(target).create(recursive: true);
      final existing = File(p.join(target, 'existing.txt'));
      await existing.writeAsString('keep me');
      await expectLater(
        manager.select(target, source: source, migrate: true),
        throwsStateError,
      );
      for (final path in [source, p.join(source, 'nested'), temporary.path]) {
        await expectLater(
          manager.select(path, source: source, migrate: true),
          throwsArgumentError,
        );
      }
      expect(await existing.readAsString(), 'keep me');
      expect(await Directory(source).exists(), isTrue);
    },
  );

  test(
    'source and destination modifications are detected before cleanup',
    () async {
      await createSource();
      await manager.select(target, source: source, migrate: true);
      await manager.activate();
      await File(p.join(source, 'new-save.dat')).writeAsBytes([1]);
      expect(await manager.completeMigration(), contains('未清理'));
      expect(await File(p.join(source, 'new-save.dat')).exists(), isTrue);
    },
  );

  test(
    'an interrupted migration resumes; damaged target files never cause source deletion',
    () async {
      await createSource();
      await manager.select(target, source: source, migrate: true);
      await manager.activate();
      expect(await manager.activate(), target);
      await File(
        p.join(target, 'appearance', 'backgrounds', 'image.png'),
      ).writeAsBytes([99]);
      await expectLater(manager.activate(), throwsStateError);
      expect(await manager.completeMigration(), contains('未清理'));
      expect(
        await File(
          p.join(source, 'appearance', 'backgrounds', 'image.png'),
        ).readAsBytes(),
        [10, 20, 30],
      );
    },
  );

  test(
    'bad source configuration and a destination populated after selection preserve both sides',
    () async {
      await Directory(source).create(recursive: true);
      await File(p.join(source, 'launcher.json')).writeAsString('broken');
      await manager.select(target, source: source, migrate: true);
      await expectLater(manager.activate(), throwsStateError);
      expect(
        await File(p.join(source, 'launcher.json')).readAsString(),
        'broken',
      );
      expect(await Directory(target).exists(), isFalse);
      await createSource();
      await Directory(target).create(recursive: true);
      await File(p.join(target, 'unrelated.txt')).writeAsString('keep');
      await expectLater(manager.activate(), throwsStateError);
      expect(
        await File(p.join(target, 'unrelated.txt')).readAsString(),
        'keep',
      );
    },
  );

  test(
    'whole-folder relocation rebases internal paths without touching arbitrary text',
    () async {
      await createSource();
      final moved = p.join(temporary.path, 'moved-data');
      await Directory(source).rename(moved);
      final loaded = LauncherController(
        supportDirectory: moved,
        platform: platform,
      );
      addTearDown(loaded.dispose);
      await loaded.initialize();
      expect(loaded.settings.gameRoot, p.join(moved, '.minecraft'));
      expect(loaded.instances.first.root, p.join(moved, '.minecraft'));
      expect(
        loaded.instances.last.root,
        p.join(temporary.path, 'external-games'),
      );
      final config = <String, dynamic>{
        'settings': {'gameRoot': source, 'gameArguments': '--title=$source'},
        'instances': [],
        'description': source,
      };
      rebaseDataPaths(config, source, moved);
      expect((config['settings'] as Map)['gameArguments'], '--title=$source');
      expect(config['description'], source);
    },
  );

  test(
    'explicit startup override bypasses the installation bootstrap',
    () async {
      final override = DataDirectoryManager(
        installationDirectory: manager.installationDirectory,
        directoryOverride: source,
      );
      expect(await override.activate(), source);
      await override.completeMigration();
      expect(await override.configuration.exists(), isFalse);
      await expectLater(override.select(target), throwsStateError);
    },
  );

  test('copy and integrity work remain off the main event loop', () async {
    await createSource();
    await File(
      p.join(source, 'large-cache.bin'),
    ).writeAsBytes(Uint8List(16 * 1024 * 1024));
    await manager.select(target, source: source, migrate: true);
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 2),
      (_) => ticks++,
    );
    try {
      await manager.activate();
    } finally {
      timer.cancel();
    }
    expect(ticks, greaterThan(2));
    expect(
      await File(p.join(target, 'large-cache.bin')).length(),
      16 * 1024 * 1024,
    );
  });
}
