import 'dart:convert';
import 'dart:io';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/pack_import.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real installed instance repair and export',
    smoke,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<void> smoke() async {
  // This explicit smoke tool exercises real services, unlike unit fixtures.
  final previousHttpOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = previousHttpOverrides);
  final record = File(
    Platform.environment['FYL_SMOKE_INSTANCE_RECORD'] ??
        p.join(
          Directory.current.path,
          'build',
          'content-smoke',
          'modpack-instance.json',
        ),
  );
  if (!p.isWithin(
    p.join(Directory.current.path, 'build'),
    p.normalize(p.absolute(record.path)),
  )) {
    throw StateError('The smoke record must be inside build.');
  }
  if (!await record.exists()) {
    throw StateError('Run tool/smoke_content.dart --install-pack first.');
  }
  final support = p.join(
    Directory.current.path,
    'build',
    'instance-tools-smoke',
  );
  final controller = LauncherController(
    supportDirectory: support,
    platform: await HostPlatform.detect(),
  );
  await controller.initialize();
  final instance =
      GameInstance.fromJson(
        jsonDecode(await record.readAsString()) as Json,
      ).copyWith(
        description: 'Smoke instance settings',
        favorite: true,
        javaMode: InstanceJavaMode.custom,
        javaPath:
            Platform.environment['FYL_TEST_JAVA'] ??
            (Platform.isWindows ? r'E:\jdk-22.0.1\bin\java.exe' : 'java'),
        launchSettings: const InstanceLaunchSettings(
          minMemory: 512,
          maxMemory: 3072,
          width: 1024,
          height: 640,
          jvmArguments: '-Dfyl.instance.settings=true',
          preLaunchCommand: '',
          verifyDownloads: true,
        ),
      );
  if (!p.equals(
    p.normalize(instance.root),
    p.normalize(p.join(Directory.current.path, 'build', 'smoke-data')),
  )) {
    throw StateError(
      'Refusing to modify an instance outside build/smoke-data.',
    );
  }
  controller.instances.clear();
  controller.instances.add(instance);
  controller.selectedId = instance.id;
  await controller.addOfflineAccount('FYL_Test');
  var previous = '';
  controller.addListener(() {
    if (controller.tasks.isNotEmpty &&
        controller.tasks.first.stage != previous) {
      previous = controller.tasks.first.stage;
      stdout.writeln('STAGE=$previous');
    }
  });
  try {
    final mods = Directory(p.join(instance.gameDirectory, 'mods'));
    await mods.create(recursive: true);
    final before = await mods
        .list()
        .where((f) => f is File)
        .map((f) => p.basename(f.path))
        .toList();
    final marker = File(
      p.join(
        instance.gameDirectory,
        'saves',
        'fyl-settings-smoke',
        'marker.txt',
      ),
    );
    await marker.parent.create(recursive: true);
    await marker.writeAsString('preserve');
    await controller.repairInstance(instance.id);
    final repaired = controller.instances.single;
    if (repaired.id != instance.id ||
        repaired.launchSettings.maxMemory != 3072 ||
        !repaired.favorite) {
      throw StateError('Instance settings were lost.');
    }
    if (await marker.readAsString() != 'preserve') {
      throw StateError('World data changed.');
    }
    final after = await mods
        .list()
        .where((f) => f is File)
        .map((f) => p.basename(f.path))
        .toList();
    if (!before.every(after.contains)) {
      throw StateError('Installed Mods changed.');
    }
    stdout.writeln('REPAIR_PRESERVES_INSTANCE_AND_DATA=true');
    final command = await MinecraftRunner(controller.platform).prepare(
      repaired,
      controller.settings,
      session: await controller.prepareSession(),
    );
    if (!command.arguments.contains('-Xmx3072M') ||
        !command.arguments.contains('-Dfyl.instance.settings=true')) {
      throw StateError('Instance launch options were not applied.');
    }
    stdout.writeln('INSTANCE_LAUNCH_OVERRIDES=true');
    final output = p.join(support, 'example-export.mrpack');
    await controller.exportPack(
      instance.id,
      output,
      folders: {'mods', 'config'},
      version: 'smoke-1',
    );
    final plan = await inspectModpack(output);
    if (plan.minecraft != instance.version ||
        plan.loaderVersion !=
            (repaired.installation['loader'] as Json?)?['version']) {
      throw StateError('Export lost pinned versions.');
    }
    stdout.writeln(
      'MRPACK_EXPORT_ROUND_TRIP=true / ${plan.overrides.length} files',
    );
    await marker.delete();
  } finally {
    controller.dispose();
  }
}
