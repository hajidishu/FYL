// Read-only local Java discovery: dart run tool/check_java.dart
import 'dart:io';

import 'package:free_your_launcher/core/java_discovery.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final platform = await HostPlatform.detect();
  final scanner = JavaDiscovery(platform);
  final results = await scanner.discover(
    runtimeRoots: [p.join(Directory.current.path, 'build', 'smoke-data')],
  );
  stdout.writeln(
    'FOUND ${results.length} Java runtimes (${platform.os}/${platform.arch})',
  );
  for (final java in results) {
    stdout.writeln(
      '${java.label} | ${java.vendor} | ${java.sources.join(', ')}\n${java.executable}',
    );
  }
}
