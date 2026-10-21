import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/instance_tools.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late LauncherController controller;
  late GameInstance version;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-layout-');
    controller = LauncherController(
      supportDirectory: p.join(temporary.path, 'fyl'),
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    version = GameInstance(
      id: 'stable-key',
      name: 'Fabric 1.21.1',
      version: '1.21.1',
      root: p.join(temporary.path, '.minecraft'),
      isolated: true,
      javaMajor: 21,
    );
    controller.instances.add(version);
    controller.selectedId = version.id;
    await File(version.metadataPath).parent.create(recursive: true);
    await File(version.metadataPath).writeAsString(
      jsonEncode({
        'id': version.name,
        'mainClass': 'example.Main',
        'libraries': [],
      }),
    );
    await File(version.clientJarPath).writeAsString('client');
  });
  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });
  Future<File> rootFile(String relative, String value) async {
    final file = File(p.join(version.root, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString(value);
  }

  test(
    'isolated/shared working directories and launch paths follow the Minecraft folder layout',
    () {
      final settings = LauncherSettings(
        gameRoot: version.root,
        username: 'Layout_Test',
      );
      for (final isolated in [true, false]) {
        final current = version.copyWith(isolated: isolated);
        final command = buildLaunchCommand(
          current,
          {
            'mainClass': 'example.Main',
            'minecraftArguments':
                r'--version ${version_name} --gameDir "${game_directory}"',
          },
          settings,
          controller.platform,
          'java',
        );
        expect(
          command.workingDirectory,
          isolated ? current.versionDirectory : current.root,
        );
        expect(
          command.arguments[command.arguments.indexOf('--gameDir') + 1],
          command.workingDirectory,
        );
        expect(command.arguments, contains(current.name));
        expect(
          command.arguments.any((a) => a.contains(current.clientJarPath)),
          isTrue,
        );
        expect(
          current.metadataPath,
          p.join(current.versionDirectory, '${current.name}.json'),
        );
      }
      expect(
        controller.settings.gameRoot,
        p.join(controller.supportDirectory, '.minecraft'),
      );
    },
  );
  test(
    'renaming changes folder/json/jar names and preserves saved settings and stable selection',
    () async {
      final world = File(
        p.join(version.gameDirectory, 'saves', 'world', 'level.dat'),
      );
      await world.parent.create(recursive: true);
      await world.writeAsString('world');
      final updated = version.copyWith(
        name: 'Renamed 1.21.1',
        favorite: true,
        launchSettings: const InstanceLaunchSettings(maxMemory: 4096),
      );
      await controller.saveInstance(updated);
      expect(await Directory(version.versionDirectory).exists(), isFalse);
      expect(await File(updated.clientJarPath).readAsString(), 'client');
      expect(
        (jsonDecode(await File(updated.metadataPath).readAsString())
            as Json)['id'],
        updated.name,
      );
      expect(
        await File(
          p.join(updated.gameDirectory, 'saves', 'world', 'level.dat'),
        ).readAsString(),
        'world',
      );
      expect(controller.selectedId, version.id);
      final restored = LauncherController(
        supportDirectory: controller.supportDirectory,
        platform: controller.platform,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.instances.single.name, updated.name);
      expect(restored.instances.single.launchSettings.maxMemory, 4096);
      expect(restored.instances.single.favorite, isTrue);
      await controller.saveInstance(updated.copyWith(name: 'RENAMED 1.21.1'));
      expect(
        (jsonDecode(
              await File(
                controller.instances.single.metadataPath,
              ).readAsString(),
            )
            as Json)['id'],
        'RENAMED 1.21.1',
      );
      expect(
        await File(controller.instances.single.clientJarPath).readAsString(),
        'client',
      );
      expect(
        await File(
          p.join(
            controller.instances.single.gameDirectory,
            'saves',
            'world',
            'level.dat',
          ),
        ).readAsString(),
        'world',
      );
    },
  );
  test(
    'renaming refuses existing folders and invalid names without changing files',
    () async {
      await rootFile('versions/Occupied/keep.txt', 'keep');
      await expectLater(
        controller.saveInstance(version.copyWith(name: 'Occupied')),
        throwsStateError,
      );
      expect(await File(version.clientJarPath).readAsString(), 'client');
      expect(
        await File(
          p.join(version.root, 'versions/Occupied/keep.txt'),
        ).readAsString(),
        'keep',
      );
      for (final name in ['../escape', r'a\b', 'CON', 'a;', 'trailing.', '']) {
        expect(validateVersionName(name), isNotNull);
        await expectLater(
          controller.saveInstance(version.copyWith(name: name)),
          throwsArgumentError,
        );
      }
    },
  );
  test(
    'copying from the shared root excludes libraries/versions and preserves the version json/jar',
    () async {
      await rootFile('saves/shared-world/level.dat', 'shared world');
      await rootFile('mods/demo.jar', 'mod');
      await rootFile('assets/keep', 'assets');
      await rootFile('libraries/keep', 'libraries');
      await rootFile('versions/Other/Other.json', '{}');
      await rootFile('.fyl/cache/keep', 'private');
      final shared = version.copyWith(isolated: false);
      await copyInstanceData(shared, version, CancellationToken());
      expect(
        await File(
          p.join(version.gameDirectory, 'saves/shared-world/level.dat'),
        ).readAsString(),
        'shared world',
      );
      expect(await File(version.clientJarPath).readAsString(), 'client');
      for (final folder in ['assets', 'libraries', 'versions']) {
        expect(
          await Directory(p.join(version.gameDirectory, folder)).exists(),
          isFalse,
        );
      }
      expect(
        await File(p.join(version.gameDirectory, '.fyl/cache/keep')).exists(),
        isFalse,
      );
      expect(
        await File(
          p.join(version.root, 'saves/shared-world/level.dat'),
        ).exists(),
        isTrue,
      );
    },
  );
  test(
    'isolation switches keep metadata fixed and only copy game data when requested',
    () async {
      await rootFile('mods/shared.jar', 'shared');
      await controller.changeInstanceIsolation(version.id, false);
      expect(controller.instances.single.gameDirectory, version.root);
      expect(controller.instances.single.metadataPath, version.metadataPath);
      expect(
        await Directory(p.join(version.versionDirectory, 'mods')).exists(),
        isFalse,
      );
      await controller.changeInstanceIsolation(
        version.id,
        true,
        copyData: true,
      );
      expect(
        await File(
          p.join(version.versionDirectory, 'mods/shared.jar'),
        ).readAsString(),
        'shared',
      );
      expect(
        await File(p.join(version.root, 'mods/shared.jar')).exists(),
        isTrue,
      );
      expect(await File(version.metadataPath).exists(), isTrue);
    },
  );
  test(
    'removing an unisolated version moves only its version folder and retains shared data',
    () async {
      controller.instances[0] = version.copyWith(isolated: false);
      await rootFile('saves/shared-world/level.dat', 'keep');
      await rootFile('mods/shared.jar', 'keep');
      final trash = await controller.removeInstance(version.id, moveData: true);
      expect(trash, isNotNull);
      expect(
        await File(p.join(trash!, '${version.name}.jar')).exists(),
        isTrue,
      );
      expect(
        await File(
          p.join(version.root, 'saves/shared-world/level.dat'),
        ).readAsString(),
        'keep',
      );
      expect(
        await File(p.join(version.root, 'mods/shared.jar')).readAsString(),
        'keep',
      );
      expect(await Directory(version.versionDirectory).exists(), isFalse);
    },
  );
}
