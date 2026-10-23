import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const _mib = 1024 * 1024;

class SystemMemory {
  final int totalMiB, availableMiB;
  const SystemMemory(this.totalMiB, this.availableMiB);
}

typedef MemoryProbe = Future<SystemMemory?> Function();

SystemMemory? _memory(int totalBytes, int availableBytes) =>
    totalBytes >= _mib && availableBytes >= 0
    ? SystemMemory(
        totalBytes ~/ _mib,
        availableBytes.clamp(0, totalBytes) ~/ _mib,
      )
    : null;

SystemMemory? parseLinuxMemory(String text) {
  final values = <String, int>{};
  for (final match in RegExp(
    r'^(\w+):\s+(\d+)\s+kB',
    multiLine: true,
  ).allMatches(text)) {
    values[match[1]!] = int.parse(match[2]!) * 1024;
  }
  final total = values['MemTotal'];
  final available =
      values['MemAvailable'] ??
      (values.containsKey('MemFree')
          ? values['MemFree']! +
                (values['Buffers'] ?? 0) +
                (values['Cached'] ?? 0) +
                (values['SReclaimable'] ?? 0) -
                (values['Shmem'] ?? 0)
          : null);
  return total == null || available == null ? null : _memory(total, available);
}

SystemMemory? parseMacMemory(String totalText, String statistics) {
  final total = int.tryParse(totalText.trim());
  final pageSize = int.tryParse(
    RegExp(r'page size of (\d+) bytes').firstMatch(statistics)?[1] ?? '',
  );
  if (total == null || pageSize == null) return null;
  var pages = 0;
  for (final name in ['free', 'inactive', 'speculative']) {
    final value = RegExp(
      '^Pages $name:\\s+(\\d+)',
      multiLine: true,
    ).firstMatch(statistics)?[1];
    if (value == null) return null;
    pages += int.parse(value);
  }
  // Count reclaimable physical pages; do not add swap or compressed pages.
  return _memory(total, pages * pageSize);
}

Future<SystemMemory?> readSystemMemory() async {
  try {
    if (Platform.isWindows) {
      final buffer = calloc<MEMORYSTATUSEX>();
      try {
        buffer.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
        if (!GlobalMemoryStatusEx(buffer).value) return null;
        return _memory(buffer.ref.ullTotalPhys, buffer.ref.ullAvailPhys);
      } finally {
        calloc.free(buffer);
      }
    }
    if (Platform.isLinux) {
      return parseLinuxMemory(await File('/proc/meminfo').readAsString());
    }
    if (Platform.isMacOS) {
      final results = await Future.wait([
        Process.run('/usr/sbin/sysctl', [
          '-n',
          'hw.memsize',
        ]).timeout(const Duration(seconds: 3)),
        Process.run('/usr/bin/vm_stat', []).timeout(const Duration(seconds: 3)),
      ]);
      if (results.any((result) => result.exitCode != 0)) return null;
      return parseMacMemory('${results[0].stdout}', '${results[1].stdout}');
    }
  } catch (_) {
    // A failed probe must not prevent starting a manually configured game.
  }
  return null;
}
