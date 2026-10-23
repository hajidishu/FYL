import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'models.dart';
import 'system_memory.dart';

class MemoryAllocation {
  final int initialMiB, maximumMiB;
  final SystemMemory? system;
  final bool automatic;
  const MemoryAllocation(
    this.initialMiB,
    this.maximumMiB, {
    required this.automatic,
    this.system,
  });

  String get initialLabel => initialMiB == 0 ? '由 Java 决定' : '$initialMiB MB';
  String get logMessage =>
      '[Launcher] 内存分配: ${automatic ? '自动' : '手动'}，初始 $initialLabel，'
      '最大 $maximumMiB MB${system == null ? '' : '，启动前可用 ${system!.availableMiB} MB'}';
}

int? _heapArgument(List<String> arguments, String flag) {
  int? result;
  for (final argument in arguments) {
    final match = RegExp('^-$flag(\\d+)([kKmMgGtT]?)\$').firstMatch(argument);
    if (match == null) continue;
    final multiplier = switch (match[2]!.toLowerCase()) {
      'k' => 1024,
      'm' => 1024 * 1024,
      'g' => 1024 * 1024 * 1024,
      't' => 1024 * 1024 * 1024 * 1024,
      _ => 1,
    };
    result = int.parse(match[1]!) * multiplier ~/ (1024 * 1024);
  }
  return result;
}

MemoryAllocation calculateMemoryAllocation(
  LauncherSettings settings,
  SystemMemory? system, {
  int modCount = 0,
  bool modded = false,
  bool optifine = false,
  bool java32Bit = false,
}) {
  final arguments = splitCommandLine(settings.jvmArguments);
  final explicitMaximum = _heapArgument(arguments, 'Xmx');
  final initial = _heapArgument(arguments, 'Xms') ?? settings.minMemory;
  final automatic = settings.automaticMemory && explicitMaximum == null;
  var maximum = explicitMaximum ?? settings.maxMemory;
  if (automatic) {
    // Mod count is a demand estimate, not a claim about each Mod's actual use.
    final demand = modded
        ? 3072 + modCount.clamp(0, 10000) * 24
        : optifine
        ? 3584
        : 3072;
    var budget = 1024;
    if (system != null) {
      final reserve = math.max(512, system.totalMiB ~/ 16);
      budget = math.min(
        math.max(256, system.availableMiB - reserve),
        math.max(256, system.totalMiB * 3 ~/ 4),
      );
    }
    maximum = math.min(demand, math.min(budget, settings.autoMemoryLimit));
    if (java32Bit) maximum = math.min(maximum, 768);
    maximum = math.max(256, maximum ~/ 128 * 128);
  }
  if (initial > maximum) {
    throw StateError(
      '初始内存 $initial MB 超过本次最大内存 $maximum MB，请降低初始内存或改为由 Java 决定。',
    );
  }
  return MemoryAllocation(
    initial,
    maximum,
    automatic: automatic,
    system: system,
  );
}

Future<int> countEnabledMods(GameInstance instance) async {
  final directory = Directory(p.join(instance.gameDirectory, 'mods'));
  if (!await directory.exists()) return 0;
  var count = 0;
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is File &&
        [
          '.jar',
          '.zip',
          '.litemod',
        ].contains(p.extension(entry.path).toLowerCase())) {
      count++;
    }
  }
  return count;
}

Future<MemoryAllocation> resolveMemoryAllocation(
  LauncherSettings settings,
  HostPlatform platform, {
  GameInstance? instance,
  MemoryProbe probe = readSystemMemory,
}) async {
  if (!settings.automaticMemory) {
    return calculateMemoryAllocation(settings, null);
  }
  SystemMemory? system;
  try {
    system = await probe();
  } catch (_) {
    /* Use the conservative fallback. */
  }
  final components = instance?.components.toLowerCase() ?? '';
  final modded =
      ['forge', 'fabric', 'quilt'].any(components.contains) ||
      instance?.installation['loader'] != null;
  var count = 0;
  if (instance != null) {
    try {
      count = await countEnabledMods(instance);
    } catch (_) {
      /* Estimate from the loader. */
    }
  }
  return calculateMemoryAllocation(
    settings,
    system,
    modCount: count,
    modded: modded || count > 0,
    optifine: components.contains('optifine'),
    java32Bit: platform.arch == 'x86',
  );
}
