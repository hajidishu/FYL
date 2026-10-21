import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/java_discovery.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:path/path.dart' as p;

String javaOutput(
  String version,
  String architecture,
  String home, {
  String vendor = 'Test OpenJDK',
}) =>
    '''
Property settings:
    java.version = $version
    java.specification.version = ${version.startsWith('1.') ? '1.8' : version.split('.').first}
    java.vendor = $vendor
    java.home = $home
    os.arch = $architecture
openjdk version "$version"
''';

void main() {
  test('reads full versions, vendors and architectures including Java 8', () {
    final modern = JavaInstallation.fromOutput(
      '/jdk/bin/java',
      javaOutput('21.0.7', 'aarch64', '/jdk', vendor: 'Microsoft'),
    )!;
    expect(modern.major, 21);
    expect(modern.version, '21.0.7');
    expect(modern.architecture, 'arm64');
    expect(modern.architectureLabel, 'ARM64');
    expect(modern.vendor, 'Microsoft');
    final old = JavaInstallation.fromOutput(
      '/jdk8/bin/java',
      javaOutput('1.8.0_461', 'amd64', '/jdk8'),
    )!;
    expect(old.major, 8);
    expect(old.architecture, 'x86_64');
    expect(
      JavaInstallation.fromOutput('/not-java', 'This is not a Java runtime'),
      isNull,
    );
    expect(
      JavaInstallation.fromOutput(
        '/unknown',
        'java.version = 21\nos.arch = ppc64le',
      )!.architecture,
      'ppc64le',
    );
  });

  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-java-discovery-');
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<String> binary(String relative, {String name = 'java.exe'}) async {
    final file = File(p.join(temporary.path, relative, 'bin', name));
    await file.parent.create(recursive: true);
    await file.writeAsString('test fixture');
    return file.resolveSymbolicLinks();
  }

  test(
    'discovers env, managed and conventional roots and deduplicates paths',
    () async {
      final system = await binary('jdk with spaces');
      final managed = await binary(
        'game/runtime/windows-x64/java-runtime-delta',
      );
      final jdk8 = await binary('installed/jdk8');
      final jre8 = await binary('installed/jdk8/jre');
      final bad = await binary('installed/broken');
      await binary('installed/jdk8/lib/unrelated');
      await binary('installed/a/b/c/too-deep');
      final calls = <String>[];
      final scanner = JavaDiscovery(
        const HostPlatform('windows', 'x86_64'),
        environment: {
          'JAVA_HOME': p.dirname(p.dirname(system)),
          'Path': '${p.dirname(system)};${p.dirname(system)}',
        },
        searchRoots: [
          JavaSearchRoot(
            p.join(temporary.path, 'installed'),
            '系统安装目录',
            depth: 2,
          ),
        ],
        runCommand: (executable, args) async {
          calls.add(executable);
          expect(args, ['-XshowSettings:properties', '-version']);
          if (executable == bad) {
            return ProcessResult(1, 1, '', 'broken executable');
          }
          final version = executable == jdk8 || executable == jre8
              ? '1.8.0_461'
              : '21.0.7';
          final home = executable == jre8
              ? p.dirname(p.dirname(jdk8))
              : p.dirname(p.dirname(executable));
          return ProcessResult(1, 0, '', javaOutput(version, 'amd64', home));
        },
      );
      final progress = <JavaScanProgress>[];
      final results = await scanner.discover(
        runtimeRoots: [p.join(temporary.path, 'game')],
        selectedJava: system,
        onProgress: progress.add,
      );
      expect(results.length, 3);
      expect(calls.where((path) => path == system).length, 1);
      expect(calls.length, 5);
      expect(
        results.firstWhere((java) => java.executable == system).sources,
        containsAll(['PATH', 'JAVA_HOME', '已设置路径']),
      );
      expect(
        results.firstWhere((java) => java.executable == managed).sources,
        contains('FYL 官方运行时'),
      );
      expect(results.last.major, 8);
      expect(progress.last.checked, 5);
      expect(progress.last.found, 3);
      expect(await File(system).readAsString(), 'test fixture');
    },
  );

  test('macOS bundle discovery skips the system install stub', () async {
    final executable = await binary(
      'JavaVirtualMachines/test.jdk/Contents/Home',
      name: 'java',
    );
    final calls = <String>[];
    final scanner = JavaDiscovery(
      const HostPlatform('osx', 'arm64'),
      environment: {'PATH': '/usr/bin'},
      searchRoots: [
        JavaSearchRoot(
          p.join(temporary.path, 'JavaVirtualMachines'),
          '系统安装目录',
          depth: 4,
        ),
      ],
      runCommand: (path, args) async {
        calls.add(path);
        return ProcessResult(
          1,
          0,
          javaOutput('21.0.7', 'aarch64', p.dirname(p.dirname(path))),
          '',
        );
      },
    );
    final results = await scanner.discover();
    expect(calls, [executable]);
    expect(results.single.architecture, 'arm64');
  });

  test(
    'cancellation stops queuing probes and permits a subsequent scan',
    () async {
      for (var index = 0; index < 10; index++) {
        await binary('installed/jdk$index');
      }
      var calls = 0;
      final scanner = JavaDiscovery(
        const HostPlatform('windows', 'x86_64'),
        environment: {},
        searchRoots: [
          JavaSearchRoot(p.join(temporary.path, 'installed'), '系统安装目录'),
        ],
        runCommand: (path, args) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return ProcessResult(
            1,
            0,
            '',
            javaOutput('21.0.7', 'amd64', p.dirname(p.dirname(path))),
          );
        },
      );
      await scanner.discover(
        onProgress: (progress) {
          if (progress.checked == 1) scanner.cancel();
        },
      );
      expect(calls, lessThanOrEqualTo(4));
      calls = 0;
      final results = await scanner.discover();
      expect(results.length, 10);
      expect(calls, 10);
    },
  );

  test(
    'architecture match sorts before a newer incompatible runtime',
    () async {
      final x64 = await binary('installed/x64');
      final arm = await binary('installed/arm');
      final scanner = JavaDiscovery(
        const HostPlatform('windows', 'x86_64'),
        environment: {},
        searchRoots: [
          JavaSearchRoot(p.join(temporary.path, 'installed'), '系统安装目录'),
        ],
        runCommand: (path, args) async => ProcessResult(
          1,
          0,
          '',
          javaOutput(
            path == arm ? '25.0.1' : '21.0.7',
            path == arm ? 'aarch64' : 'amd64',
            p.dirname(p.dirname(path)),
          ),
        ),
      );
      final results = await scanner.discover();
      expect(results.map((java) => java.executable), [x64, arm]);
    },
  );
}
