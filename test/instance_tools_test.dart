import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/instance_tools.dart';
import 'package:free_your_launcher/core/local_mods.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/pack_import.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late GameInstance instance;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-instance-tools-');
    instance = GameInstance(
      id: 'test',
      name: 'Example',
      version: '1.21.1',
      root: temporary.path,
      isolated: true,
      javaMajor: 21,
      components: 'Fabric 0.16.10',
      installation: {
        'loader': {'type': 'fabric', 'version': '0.16.10'},
      },
    );
    await Directory(instance.gameDirectory).create(recursive: true);
  });
  tearDown(() async => temporary.delete(recursive: true));
  Future<File> file(String relative, String contents) async {
    final output = File(p.join(instance.gameDirectory, relative));
    await output.parent.create(recursive: true);
    return output.writeAsString(contents);
  }

  Future<File> jar(String name, Map<String, String> entries) async {
    final archive = Archive();
    for (final entry in entries.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    final result = File(p.join(instance.gameDirectory, 'mods', name));
    await result.parent.create(recursive: true);
    return result.writeAsBytes(ZipEncoder().encode(archive));
  }

  test(
    'instance overrides survive round trips and affect the actual launch command',
    () {
      final defaults = LauncherSettings(
        gameRoot: temporary.path,
        username: 'Test_User',
        maxMemory: 2048,
        jvmArguments: '-Dglobal=true',
        gameArguments: '--global',
        preLaunchCommand: 'global-hook',
      );
      final edited = instance.copyWith(
        name: 'Renamed',
        description: 'Description',
        category: 'Adventure',
        favorite: true,
        launchSettings: const InstanceLaunchSettings(
          minMemory: 768,
          maxMemory: 4096,
          width: 1440,
          height: 900,
          fullscreen: false,
          jvmArguments: '-Dlocal="has space"',
          gameArguments: '--server localhost',
          preLaunchCommand: '',
          verifyDownloads: false,
        ),
      );
      final restored = GameInstance.fromJson(
        edited.toJson(),
      ).withJava(InstanceJavaMode.custom, 'my-java');
      defaults.maxMemory = 8192;
      final effective = restored.effectiveSettings(defaults);
      expect(effective.maxMemory, 4096);
      expect(defaults.jvmArguments, '-Dglobal=true');
      expect(effective.preLaunchCommand, isEmpty);
      expect(effective.verifyDownloads, isFalse);
      expect(restored.description, 'Description');
      expect(restored.favorite, isTrue);
      final command = buildLaunchCommand(
        restored,
        {
          'mainClass': 'test.Main',
          'minecraftArguments': '--username \${auth_player_name}',
        },
        defaults,
        const HostPlatform('windows', 'x86_64'),
        'my-java',
      );
      expect(
        command.arguments,
        containsAll([
          '-Xms768M',
          '-Xmx4096M',
          '-Dlocal=has space',
          '--server',
          'localhost',
          '1440',
          '900',
        ]),
      );
      expect(command.arguments, isNot(contains('-Dglobal=true')));
      expect(instance.effectiveSettings(defaults).maxMemory, 8192);
      final legacy = instance.toJson()..remove('launchSettings');
      expect(
        GameInstance.fromJson(legacy).effectiveSettings(defaults).maxMemory,
        8192,
      );
    },
  );
  test(
    'Fabric, Forge, NeoForge and legacy metadata are readable without loading code',
    () async {
      final fabric = await jar('fabric.jar', {
        'fabric.mod.json': jsonEncode({
          'id': 'demo',
          'name': 'Demo Mod',
          'version': '1.2',
          'description': 'Fabric description',
        }),
      });
      final lenient = await jar('lenient.jar', {
        'fabric.mod.json':
            '{\n// comment\n"id":"lenient", "description":"First line\nSecond line",\n}',
      });
      expect(readLocalMod(lenient.path).description, 'First line\nSecond line');
      final forge = await jar('forge.jar.disabled', {
        'META-INF/mods.toml':
            '''modLoader="javafml"
[[mods]]
modId="forge_demo"
version="\${file.jarVersion}"
displayName="Forge Demo"
description='''
            "'''"
            '''Multiple
lines'''
            "'''"
            '''
[[dependencies.forge_demo]]
modId="minecraft"
''',
        'META-INF/MANIFEST.MF': 'Implementation-Version: 2.3\r\n',
      });
      final neo = await jar('neo.jar', {
        'META-INF/neoforge.mods.toml':
            '[[mods]]\nmodId="neo"\ndisplayName="Neo Demo"\nversion="3"',
      });
      await jar('legacy.jar', {
        'mcmod.info': jsonEncode([
          {'modid': 'legacy', 'name': 'Legacy Demo', 'version': '0.1'},
        ]),
      });
      await file('mods/broken.jar', 'not a jar');
      expect(readLocalMod(fabric.path).name, 'Demo Mod');
      final f = readLocalMod(forge.path);
      expect(f.name, 'Forge Demo');
      expect(f.version, '2.3');
      expect(f.enabled, isFalse);
      expect(f.description, 'Multiple\nlines');
      expect(readLocalMod(neo.path).loader, 'NeoForge');
      final all = await scanLocalMods(instance, CancellationToken());
      expect(all.length, 6);
      expect(all.where((m) => m.name == 'Legacy Demo'), hasLength(1));
      expect(all.where((m) => m.warning != null), hasLength(1));
    },
  );
  test(
    'batch enable checks collisions first, and removal keeps recoverable files',
    () async {
      final first = await jar('one.jar', {});
      final second = await jar('two.jar', {});
      await file('mods/two.jar.disabled', 'existing');
      await expectLater(
        setModsEnabled(instance, [
          readLocalMod(first.path),
          readLocalMod(second.path),
        ], false),
        throwsStateError,
      );
      expect(await first.exists(), isTrue);
      expect(await second.exists(), isTrue);
      await setModsEnabled(instance, [readLocalMod(first.path)], false);
      expect(await File('${first.path}.disabled').exists(), isTrue);
      await setModsEnabled(instance, [
        readLocalMod('${first.path}.disabled'),
      ], true);
      final removed = await trashLocalMods(instance, [
        readLocalMod(first.path),
      ]);
      expect(await first.exists(), isFalse);
      expect(await File(p.join(removed, 'one.jar')).exists(), isTrue);
      expect(await second.exists(), isTrue);
      final outside = await File(
        p.join(temporary.path, 'outside.jar'),
      ).writeAsString('outside');
      await expectLater(
        trashLocalMods(instance, [readLocalMod(outside.path)]),
        throwsFormatException,
      );
      expect(await outside.exists(), isTrue);
    },
  );
  test(
    'local Mod import validates archives and requires explicit replacement',
    () async {
      final original = await jar('demo.jar', {
        'fabric.mod.json': '{"id":"original"}',
      });
      final source = File(p.join(temporary.path, 'demo.jar'));
      final archive = Archive()
        ..addFile(ArchiveFile.string('fabric.mod.json', '{"id":"updated"}'));
      await source.writeAsBytes(ZipEncoder().encode(archive));
      await expectLater(
        importLocalMods(instance, [source.path]),
        throwsStateError,
      );
      expect(readLocalMod(original.path).id, 'original');
      await importLocalMods(instance, [source.path], replace: true);
      expect(readLocalMod(original.path).id, 'updated');
      final conflictingSource = File(p.join(temporary.path, 'conflict.jar'));
      await conflictingSource.writeAsBytes(ZipEncoder().encode(archive));
      final nextUpdate = Archive()
        ..addFile(
          ArchiveFile.string('fabric.mod.json', '{"id":"second_update"}'),
        );
      await source.writeAsBytes(ZipEncoder().encode(nextUpdate));
      await Directory(
        p.join(instance.gameDirectory, 'mods', 'conflict.jar'),
      ).create();
      await expectLater(
        importLocalMods(instance, [
          source.path,
          conflictingSource.path,
        ], replace: true),
        throwsFormatException,
      );
      expect(readLocalMod(original.path).id, 'updated');
    },
  );
  test(
    'exported mrpack round-trips exact loader and only explicitly selected game data',
    () async {
      await jar('demo.jar', {'fabric.mod.json': '{"id":"demo"}'});
      await file('config/demo.txt', 'config');
      await file('saves/world/level.dat', 'world');
      await file('options.txt', 'music:0');
      await file('.launcher/private.json', 'SECRET');
      final output = p.join(temporary.path, 'export.mrpack');
      final count = await exportInstancePack(
        instance,
        output,
        CancellationToken(),
        folders: {'mods', 'config'},
        version: '2.0',
      );
      expect(count, 3);
      final plan = await inspectModpack(output);
      expect(plan.minecraft, '1.21.1');
      expect(plan.loaderVersion, '0.16.10');
      expect(
        plan.overrides.keys,
        containsAll(['mods/demo.jar', 'config/demo.txt', 'options.txt']),
      );
      expect(
        plan.overrides.keys.any(
          (p) => p.contains('saves') || p.contains('private'),
        ),
        isFalse,
      );
      await expectLater(
        exportInstancePack(
          instance,
          p.join(instance.gameDirectory, 'bad.mrpack'),
          CancellationToken(),
          folders: {'mods'},
          version: '1',
        ),
        throwsArgumentError,
      );
      final cancelled = CancellationToken()..cancel();
      await expectLater(
        exportInstancePack(
          instance,
          p.join(temporary.path, 'cancelled.mrpack'),
          cancelled,
          folders: {'mods'},
          version: '1',
        ),
        throwsA(isA<Cancelled>()),
      );
      expect(
        await File(p.join(temporary.path, 'cancelled.mrpack')).exists(),
        isFalse,
      );
    },
  );
  test(
    'directory switching copies game data only and rejects conflicting files',
    () async {
      final shared = instance.copyWith(isolated: false);
      await file('saves/world/level.dat', 'world');
      await copyInstanceData(instance, shared, CancellationToken());
      expect(
        await File(
          p.join(shared.gameDirectory, 'saves/world/level.dat'),
        ).readAsString(),
        'world',
      );
      expect(
        await File(
          p.join(instance.gameDirectory, 'saves/world/level.dat'),
        ).readAsString(),
        'world',
      );
      await copyInstanceData(instance, shared, CancellationToken());
      await File(
        p.join(shared.gameDirectory, 'saves/world/level.dat'),
      ).writeAsString('different');
      await expectLater(
        copyInstanceData(instance, shared, CancellationToken()),
        throwsStateError,
      );
    },
  );
  test(
    'removing an isolated instance preserves shared libraries and recoverable saves',
    () async {
      final controller = LauncherController(
        supportDirectory: p.join(temporary.path, 'launcher'),
        platform: const HostPlatform('windows', 'x86_64'),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      controller.instances.add(instance);
      await file('saves/world/level.dat', 'world');
      final library = File(p.join(temporary.path, 'libraries/shared.jar'));
      await library.parent.create(recursive: true);
      await library.writeAsString('shared');
      final moved = await controller.removeInstance(
        instance.id,
        moveData: true,
      );
      expect(controller.instances, isEmpty);
      expect(await library.readAsString(), 'shared');
      expect(
        await File(p.join(moved!, 'saves/world/level.dat')).readAsString(),
        'world',
      );
      controller.instances.add(instance.copyWith(isolated: false));
      await controller.removeInstance(instance.id, moveData: true);
      expect(await library.exists(), isTrue);
    },
  );
  test(
    'exported shell scripts preserve literal arguments and avoid shell expansion',
    () {
      final command = LaunchCommand('/path with space/java', [
        r'-Dvalue=$HOME',
        "a'b",
        'line\nnext',
      ], temporary.path);
      final sh = launchScript(command, const HostPlatform('linux', 'x86_64'));
      expect(sh, contains("'-Dvalue=\$HOME'"));
      expect(sh, contains("'a'\"'\"'b'"));
      final ps = launchScript(command, const HostPlatform('windows', 'x86_64'));
      expect(ps, contains("'a''b'"));
      expect(ps, startsWith('\uFEFF'));
      expect(ps, contains('Set-Location -LiteralPath'));
    },
  );
  test(
    'prelaunch commands run in the instance directory, report failure and time out',
    () async {
      final windows = Platform.isWindows;
      final host = HostPlatform(windows ? 'windows' : 'linux', 'x86_64');
      final result = await runPreLaunchCommand(
        windows ? 'echo hello & cd' : 'echo hello; pwd',
        instance.gameDirectory,
        host,
      );
      expect(result.exitCode, 0);
      expect('${result.stdout}', contains('hello'));
      expect('${result.stdout}', contains(p.basename(instance.gameDirectory)));
      final failed = await runPreLaunchCommand(
        windows ? 'exit /b 7' : 'exit 7',
        instance.gameDirectory,
        host,
      );
      expect(failed.exitCode, 7);
      await expectLater(
        runPreLaunchCommand(
          windows ? 'ping -n 10 127.0.0.1 > nul' : 'sleep 5',
          instance.gameDirectory,
          host,
          timeout: const Duration(milliseconds: 100),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'repair reuses the instance identity and does not touch saves or launch overrides',
    () async {
      final bytes = utf8.encode('client');
      final network = RepairFixtureNetwork(
        LauncherSettings(
          gameRoot: temporary.path,
          automaticJava: false,
          javaPath: 'java',
        ),
        bytes,
      );
      addTearDown(network.close);
      final customized = instance.copyWith(
        description: 'custom',
        favorite: true,
        launchSettings: const InstanceLaunchSettings(maxMemory: 4096),
      );
      await file('saves/world/level.dat', 'world');
      final task = InstallTask(
        MinecraftVersion.fromJson({
          'id': '1.21.1',
          'type': 'release',
          'url': 'https://example.test/version',
          'releaseTime': '2024-01-01T00:00:00Z',
        }),
        instance.name,
        network.settings,
      );
      final repaired = await MinecraftInstaller(
        const HostPlatform('windows', 'x86_64'),
        network,
      ).install(task, CancellationToken(), () {}, existingInstance: customized);
      expect(repaired.id, instance.id);
      expect(repaired.createdAt, instance.createdAt);
      expect(repaired.favorite, isTrue);
      expect(repaired.launchSettings.maxMemory, 4096);
      expect(
        await File(
          p.join(repaired.gameDirectory, 'saves/world/level.dat'),
        ).readAsString(),
        'world',
      );
      expect(await File(repaired.clientJarPath).readAsBytes(), bytes);
    },
  );
}

class RepairFixtureNetwork extends OfficialNetwork {
  final List<int> bytes;
  RepairFixtureNetwork(super.settings, this.bytes);
  @override
  Future<Json> json(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async => {
    'id': '1.21.1',
    'mainClass': 'test.Main',
    'libraries': [],
    'downloads': {
      'client': {
        'url': 'https://example.test/client',
        'sha1': sha1.convert(bytes).toString(),
        'size': bytes.length,
      },
    },
  };
  @override
  Future<void> downloadAll(
    List<DownloadFile> files,
    CancellationToken token, {
    void Function(int, int, String)? onProgress,
    void Function(int)? onBytes,
    void Function(int)? onCachedBytes,
  }) async {
    for (var i = 0; i < files.length; i++) {
      await File(files[i].path).parent.create(recursive: true);
      await File(files[i].path).writeAsBytes(bytes);
      onProgress?.call(i + 1, files.length, files[i].path);
    }
  }
}
