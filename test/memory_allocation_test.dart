import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/memory_allocation.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/system_memory.dart';
import 'package:path/path.dart' as p;

class FixtureRunner extends MinecraftRunner {
  FixtureRunner(super.platform, {required super.memoryProbe});
  @override
  Future<String> javaFor(
    GameInstance instance,
    LauncherSettings settings,
  ) async => 'fixture-java';
}

void main() {
  const platform = HostPlatform('windows', 'x86_64');
  LauncherSettings settings() => LauncherSettings(
    gameRoot: Directory.systemTemp.path,
    username: 'Test_User',
  );

  test(
    'new settings use automatic maximum and Java-managed initial memory',
    () {
      final value = settings();
      expect(value.automaticMemory, isTrue);
      expect(value.minMemory, 0);
      expect(value.validate(), isNull);
      expect(
        LauncherSettings.fromJson(value.toJson(), '').toJson(),
        value.toJson(),
      );
      final legacy = LauncherSettings.fromJson({
        'minMemory': 768,
        'maxMemory': 8192,
      }, Directory.systemTemp.path);
      expect(legacy.automaticMemory, isFalse);
      expect(legacy.minMemory, 768);
      expect(legacy.maxMemory, 8192);
    },
  );

  test(
    'instance modes inherit, override, and preserve existing manual settings',
    () {
      final defaults = settings();
      expect(
        const InstanceLaunchSettings().apply(defaults).automaticMemory,
        isTrue,
      );
      final legacy = InstanceLaunchSettings.fromJson({'maxMemory': 4096});
      expect(legacy.apply(defaults).automaticMemory, isFalse);
      expect(legacy.apply(defaults).maxMemory, 4096);
      final own = InstanceLaunchSettings.fromJson(
        const InstanceLaunchSettings(
          automaticMemory: true,
          autoMemoryLimit: 6144,
          minMemory: 0,
          maxMemory: 4096,
        ).toJson(),
      );
      expect(own.apply(defaults).automaticMemory, isTrue);
      expect(own.apply(defaults).autoMemoryLimit, 6144);
      expect(defaults.autoMemoryLimit, 16384);
    },
  );

  test(
    'auto memory accounts for demand, free physical memory, and user ceiling',
    () {
      final value = settings();
      const plenty = SystemMemory(32768, 24576);
      final vanilla = calculateMemoryAllocation(value, plenty);
      final modded = calculateMemoryAllocation(
        value,
        plenty,
        modded: true,
        modCount: 200,
      );
      expect(modded.maximumMiB, greaterThan(vanilla.maximumMiB));
      expect(
        calculateMemoryAllocation(
          value,
          const SystemMemory(32768, 4096),
          modded: true,
          modCount: 200,
        ).maximumMiB,
        lessThan(modded.maximumMiB),
      );
      value.autoMemoryLimit = 3200;
      expect(
        calculateMemoryAllocation(
          value,
          plenty,
          modded: true,
          modCount: 200,
        ).maximumMiB,
        lessThanOrEqualTo(3200),
      );
      expect(
        calculateMemoryAllocation(value, plenty, java32Bit: true).maximumMiB,
        lessThanOrEqualTo(768),
      );
      expect(calculateMemoryAllocation(value, null).maximumMiB, 1024);
      for (final available in [0, 200, 512, 1024, 2048, 8192, 20000]) {
        final plan = calculateMemoryAllocation(
          value,
          SystemMemory(32768, available),
          modded: true,
          modCount: 10000,
        );
        expect(plan.maximumMiB, inInclusiveRange(256, 3200));
        expect(plan.maximumMiB % 128, 0);
        if (available >= 2304) {
          expect(plan.maximumMiB, lessThanOrEqualTo(available - 2048));
        }
      }
    },
  );

  test(
    'manual heap and explicit JVM parameters are respected and validated',
    () {
      final value = settings()
        ..automaticMemory = false
        ..minMemory = 768
        ..maxMemory = 8192;
      final manual = calculateMemoryAllocation(
        value,
        const SystemMemory(16384, 2048),
      );
      expect(manual.maximumMiB, 8192);
      value.automaticMemory = true;
      value.jvmArguments = '-Xms1G -Xmx4G -Xmx6G';
      final explicit = calculateMemoryAllocation(value, null);
      expect(explicit.initialMiB, 1024);
      expect(explicit.maximumMiB, 6144);
      expect(explicit.automatic, isFalse);
      value.jvmArguments = '';
      value.minMemory = 8192;
      expect(() => calculateMemoryAllocation(value, null), throwsStateError);
    },
  );

  test('Linux available RAM excludes swap and macOS supports 4K and 16K pages', () {
    final linux = parseLinuxMemory(
      'MemTotal: 16777216 kB\nMemAvailable: 8388608 kB\nSwapFree: 99999999 kB\n',
    );
    expect(linux!.totalMiB, 16384);
    expect(linux.availableMiB, 8192);
    expect(parseLinuxMemory('SwapFree: 10000 kB'), isNull);
    for (final page in [4096, 16384]) {
      final mac = parseMacMemory(
        '17179869184\n',
        'Mach Virtual Memory Statistics: (page size of $page bytes)\n'
            'Pages free: 100000.\nPages inactive: 200000.\nPages speculative: 10000.\n'
            'Pages occupied by compressor: 999999.\n',
      );
      expect(mac!.availableMiB, 310000 * page ~/ (1024 * 1024));
    }
    expect(parseMacMemory('bad', ''), isNull);
  });

  test('native memory probe returns plausible physical memory', () async {
    final value = await readSystemMemory();
    expect(value, isNotNull);
    expect(value!.totalMiB, greaterThan(0));
    expect(value.availableMiB, inInclusiveRange(0, value.totalMiB));
  });

  test(
    'actual launch recalculates memory without restoring saved heap values',
    () async {
      final directory = await Directory.systemTemp.createTemp('fyl-memory-');
      addTearDown(() => directory.delete(recursive: true));
      final instance = GameInstance(
        id: 'game',
        name: 'Game',
        version: '1.21.1',
        root: directory.path,
        isolated: true,
        javaMajor: 21,
        components: 'Fabric 0.16.10',
        launchSettings: const InstanceLaunchSettings(
          automaticMemory: true,
          autoMemoryLimit: 6144,
          minMemory: 0,
          maxMemory: 8192,
        ),
      );
      await Directory(instance.versionDirectory).create(recursive: true);
      await File(instance.clientJarPath).writeAsBytes([0]);
      await File(instance.metadataPath).writeAsString(
        jsonEncode({
          'mainClass': 'example.Main',
          'minecraftArguments': '--username \${auth_player_name}',
        }),
      );
      final mods = Directory(p.join(instance.gameDirectory, 'mods'));
      await mods.create(recursive: true);
      for (var i = 0; i < 50; i++) {
        await File(p.join(mods.path, '$i.jar')).writeAsBytes([]);
        await File(p.join(mods.path, '$i.jar.disabled')).writeAsBytes([]);
      }
      expect(await countEnabledMods(instance), 50);
      var available = 10000;
      final runner = FixtureRunner(
        platform,
        memoryProbe: () async => SystemMemory(16384, available),
      );
      final value = settings()..gameRoot = directory.path;
      final first = await runner.prepare(instance, value);
      expect(first.arguments.where((arg) => arg.startsWith('-Xms')), isEmpty);
      expect(first.arguments, contains('-Xmx${first.memory!.maximumMiB}M'));
      expect(first.memory!.maximumMiB, lessThan(6144));
      expect(first.memory!.logMessage, contains('由 Java 决定'));
      available = 2500;
      final second = await runner.prepare(instance, value);
      expect(second.memory!.maximumMiB, lessThan(first.memory!.maximumMiB));
      expect(instance.launchSettings.maxMemory, 8192);
      expect(value.maxMemory, 2048);
      value.jvmArguments = '-Xmx4G -Xms1G';
      final explicit = await runner.prepare(instance, value);
      expect(explicit.arguments.where((arg) => arg.startsWith('-Xmx')), [
        '-Xmx4G',
      ]);
      expect(explicit.arguments.where((arg) => arg.startsWith('-Xms')), [
        '-Xms1G',
      ]);
      expect(explicit.memory!.maximumMiB, 4096);
    },
  );
}
