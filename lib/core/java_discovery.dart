import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

typedef JavaCommandRunner =
    Future<ProcessResult?> Function(String executable, List<String> arguments);

class JavaInstallation {
  final String executable;
  final String version;
  final int major;
  final String architecture;
  final String vendor;
  final String home;
  final Set<String> sources;

  JavaInstallation({
    required this.executable,
    required this.version,
    required this.major,
    required this.architecture,
    required this.vendor,
    required this.home,
    required this.sources,
  });

  String get architectureLabel => switch (architecture) {
    'x86_64' => 'x64',
    'arm64' => 'ARM64',
    'x86' => 'x86',
    _ => architecture,
  };
  String get label => 'Java $version · $architectureLabel';

  static JavaInstallation? fromOutput(
    String executable,
    String output, {
    String source = '',
  }) {
    final properties = <String, String>{};
    for (final line in const LineSplitter().convert(output)) {
      final property = RegExp(r'^\s*([\w.]+)\s*=\s*(.*?)\s*$').firstMatch(line);
      if (property != null) properties[property[1]!] = property[2]!;
    }
    final version =
        properties['java.version'] ??
        RegExp(
          r'(?:openjdk|java)\s+(?:version\s+)?"?([\d][^\s"]*)',
        ).firstMatch(output)?.group(1);
    if (version == null) return null;
    final feature = properties['java.specification.version'] ?? version;
    final match = RegExp(r'^(?:1\.)?(\d+)').firstMatch(feature);
    if (match == null) return null;
    final major = int.tryParse(match[1]!);
    if (major == null || major < 1) return null;
    final architecture = switch (properties['os.arch']?.toLowerCase()) {
      'amd64' || 'x86_64' || 'x64' => 'x86_64',
      'aarch64' || 'arm64' => 'arm64',
      'x86' || 'i386' || 'i486' || 'i586' || 'i686' => 'x86',
      final String value => value,
      _ => '未知架构',
    };
    return JavaInstallation(
      executable: executable,
      version: version,
      major: major,
      architecture: architecture,
      vendor:
          properties['java.vendor'] ?? properties['java.vm.vendor'] ?? '未知发行商',
      home: properties['java.home'] ?? p.dirname(p.dirname(executable)),
      sources: {if (source.isNotEmpty) source},
    );
  }
}

class JavaSearchRoot {
  final String path;
  final String source;
  final int depth;
  const JavaSearchRoot(this.path, this.source, {this.depth = 3});
}

class JavaScanProgress {
  final int checked;
  final int found;
  const JavaScanProgress(this.checked, this.found);
}

/// Bounded, read-only discovery of actual Java binaries, not a whole-disk search.
class JavaDiscovery {
  final HostPlatform platform;
  final Map<String, String> environment;
  final JavaCommandRunner? runCommand;
  final List<JavaSearchRoot>? searchRoots;
  final Duration commandTimeout;
  final _processes = <Process>{};
  bool _cancelled = false;
  bool _scanning = false;

  JavaDiscovery(
    this.platform, {
    Map<String, String>? environment,
    this.runCommand,
    this.searchRoots,
    this.commandTimeout = const Duration(seconds: 5),
  }) : environment = environment ?? Platform.environment;

  void cancel() {
    _cancelled = true;
    for (final process in _processes.toList()) {
      process.kill();
    }
  }

  String? _env(String name) {
    if (platform.os != 'windows') return environment[name];
    for (final entry in environment.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }

  String _key(String path) => platform.os == 'windows'
      ? p.normalize(path).toLowerCase()
      : p.normalize(path);

  List<JavaSearchRoot> _standardRoots() {
    final roots = <JavaSearchRoot>[];
    final home = _env(platform.os == 'windows' ? 'USERPROFILE' : 'HOME');
    if (home != null) {
      roots.addAll([
        JavaSearchRoot(p.join(home, '.jdks'), '用户 Java'),
        JavaSearchRoot(p.join(home, '.sdkman', 'candidates', 'java'), 'SDKMAN'),
        JavaSearchRoot(p.join(home, '.jabba', 'jdk'), 'Jabba'),
      ]);
    }
    if (platform.os == 'windows') {
      for (final directory in {
        _env('ProgramW6432'),
        _env('ProgramFiles'),
        _env('ProgramFiles(x86)'),
      }.nonNulls) {
        for (final vendor in [
          'Java',
          'Eclipse Adoptium',
          'AdoptOpenJDK',
          'Microsoft',
          'Zulu',
          'BellSoft',
          'Amazon Corretto',
          'Semeru',
          'OpenLogic',
          'GraalVM',
        ]) {
          roots.add(JavaSearchRoot(p.join(directory, vendor), '系统安装目录'));
        }
        roots.add(
          JavaSearchRoot(
            p.join(directory, 'Android', 'Android Studio', 'jbr'),
            'Android Studio',
          ),
        );
      }
      final local = _env('LOCALAPPDATA');
      if (local != null) {
        for (final vendor in [
          'Eclipse Adoptium',
          'Java',
          'Programs/Eclipse Adoptium',
          'Programs/Microsoft',
        ]) {
          roots.add(
            JavaSearchRoot(
              p.join(local, p.joinAll(vendor.split('/'))),
              '用户安装目录',
            ),
          );
        }
      }
    } else if (platform.os == 'osx') {
      roots.add(
        const JavaSearchRoot(
          '/Library/Java/JavaVirtualMachines',
          '系统安装目录',
          depth: 4,
        ),
      );
      if (home != null) {
        roots.add(
          JavaSearchRoot(
            p.join(home, 'Library', 'Java', 'JavaVirtualMachines'),
            '用户 Java',
            depth: 4,
          ),
        );
      }
      roots.addAll(const [
        JavaSearchRoot('/opt/homebrew/opt', 'Homebrew', depth: 4),
        JavaSearchRoot('/usr/local/opt', 'Homebrew', depth: 4),
      ]);
    } else {
      roots.addAll(const [
        JavaSearchRoot('/usr/lib/jvm', '系统安装目录'),
        JavaSearchRoot('/usr/java', '系统安装目录'),
        JavaSearchRoot('/opt/java', '系统安装目录'),
      ]);
    }
    return roots;
  }

  Future<ProcessResult?> _run(String executable, List<String> arguments) async {
    if (_cancelled) return null;
    if (runCommand != null) return runCommand!(executable, arguments);
    Process? process;
    try {
      process = await Process.start(executable, arguments, runInShell: false);
      _processes.add(process);
      if (_cancelled) process.kill();
      // Drain both pipes concurrently before waiting for completion.
      final result = await Future.wait<Object>([
        process.exitCode,
        process.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .join(),
        process.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .join(),
      ]).timeout(commandTimeout);
      return ProcessResult(process.pid, result[0] as int, result[1], result[2]);
    } on TimeoutException {
      process?.kill();
      return null;
    } on ProcessException {
      return null;
    } on FileSystemException {
      return null;
    } finally {
      if (process != null) _processes.remove(process);
    }
  }

  Future<List<JavaInstallation>> discover({
    List<String> runtimeRoots = const [],
    String? selectedJava,
    void Function(JavaScanProgress)? onProgress,
  }) async {
    if (_scanning) throw StateError('Java 查找正在进行');
    _scanning = true;
    _cancelled = false;
    final candidates = <String, (String, Set<String>)>{};
    final visited = <String>{};
    final binary = platform.javaBinary;
    try {
      Future<void> add(String path, String source) async {
        if (_cancelled || path.isEmpty) return;
        // /usr/bin/java is a macOS stub which can prompt the user to install Java.
        if (platform.os == 'osx' && p.normalize(path) == '/usr/bin/java') {
          return;
        }
        try {
          final file = File(path);
          if (!await file.exists()) return;
          final canonical = await file.resolveSymbolicLinks();
          if (platform.os == 'osx' && canonical == '/usr/bin/java') return;
          final key = _key(canonical);
          final existing = candidates[key];
          if (existing != null) {
            existing.$2.add(source);
          } else {
            candidates[key] = (canonical, {source});
          }
        } on FileSystemException {
          /* Missing or inaccessible locations are normal. */
        }
      }

      var visitedCount = 0;
      Future<void> walk(JavaSearchRoot root) async {
        if (_cancelled || visitedCount >= 4096) return;
        try {
          final directory = Directory(root.path);
          if (!await directory.exists()) return;
          final canonical = await directory.resolveSymbolicLinks();
          if (!visited.add(_key(canonical))) return;
          visitedCount++;
          final executable = p.join(root.path, 'bin', binary);
          if (await File(executable).exists()) {
            await add(executable, root.source);
            // Java 8 JDKs sometimes expose a second copy under jre/bin.
            await add(p.join(root.path, 'jre', 'bin', binary), root.source);
            return;
          }
          if (root.depth <= 0) return;
          await for (final child in directory.list(followLinks: false)) {
            if (_cancelled || visitedCount >= 4096) break;
            final name = p.basename(child.path).toLowerCase();
            if (const {
              'bin',
              'lib',
              'include',
              'jmods',
              'legal',
              'src',
              'demo',
              'man',
              'node_modules',
              '.git',
            }.contains(name)) {
              continue;
            }
            if (child is Directory ||
                child is Link && await Directory(child.path).exists()) {
              await walk(
                JavaSearchRoot(child.path, root.source, depth: root.depth - 1),
              );
            }
          }
        } on FileSystemException {
          /* Continue scanning other installation roots. */
        }
      }

      if (selectedJava?.trim().isNotEmpty == true) {
        await add(selectedJava!.trim(), '已设置路径');
      }
      final javaHome = _env('JAVA_HOME');
      if (javaHome != null) {
        await add(
          p.join(javaHome.replaceAll('"', ''), 'bin', binary),
          'JAVA_HOME',
        );
      }
      for (final entry in (_env('PATH') ?? '').split(
        platform.os == 'windows' ? ';' : ':',
      )) {
        final directory = entry.trim().replaceAll('"', '');
        if (directory.isNotEmpty && p.isAbsolute(directory)) {
          await add(p.join(directory, binary), 'PATH');
        }
      }
      for (final root in runtimeRoots.toSet()) {
        if (root.isNotEmpty) {
          await walk(
            JavaSearchRoot(p.join(root, 'runtime'), 'FYL 官方运行时', depth: 6),
          );
        }
      }
      for (final root in searchRoots ?? _standardRoots()) {
        await walk(root);
      }

      if (searchRoots == null && platform.os == 'windows') {
        final systemRoot = _env('SystemRoot') ?? r'C:\Windows';
        for (final key in [
          r'HKLM\SOFTWARE\JavaSoft',
          r'HKLM\SOFTWARE\WOW6432Node\JavaSoft',
          r'HKLM\SOFTWARE\Eclipse Adoptium',
          r'HKCU\SOFTWARE\JavaSoft',
        ]) {
          if (_cancelled) break;
          final result = await _run(p.join(systemRoot, 'System32', 'reg.exe'), [
            'query',
            key,
            '/s',
          ]);
          if (result?.exitCode != 0) continue;
          for (final line in const LineSplitter().convert(
            '${result!.stdout}',
          )) {
            final match = RegExp(
              r'^\s*(?:JavaHome|Path)\s+REG_(?:EXPAND_)?SZ\s+(.+?)\s*$',
            ).firstMatch(line);
            if (match != null) {
              await add(p.join(match[1]!, 'bin', binary), '注册表');
            }
          }
        }
      } else if (searchRoots == null && platform.os == 'osx' && !_cancelled) {
        final result = await _run('/usr/libexec/java_home', ['-V']);
        if (result?.exitCode == 0) {
          for (final line in const LineSplitter().convert(
            '${result!.stdout}\n${result.stderr}',
          )) {
            final match = RegExp(r'(/.+?)\s*$').firstMatch(line);
            if (match != null) {
              await add(p.join(match[1]!, 'bin', binary), '系统 Java 查询');
            }
          }
        }
      }

      final results = <String, JavaInstallation>{};
      final pending = candidates.values.toList();
      var cursor = 0;
      var checked = 0;
      onProgress?.call(const JavaScanProgress(0, 0));
      Future<void> worker() async {
        while (!_cancelled && cursor < pending.length) {
          final (path, sources) = pending[cursor++];
          final result = await _run(path, [
            '-XshowSettings:properties',
            '-version',
          ]);
          if (_cancelled) break;
          final installation = result?.exitCode == 0
              ? JavaInstallation.fromOutput(
                  path,
                  '${result!.stdout}\n${result.stderr}',
                )
              : null;
          if (installation != null) {
            String home;
            try {
              home = await Directory(installation.home).resolveSymbolicLinks();
            } on FileSystemException {
              home = installation.home;
            }
            final key =
                '${_key(home)}|${installation.version}|${installation.architecture}';
            final existing = results[key];
            if (existing != null) {
              existing.sources.addAll(sources);
            } else {
              installation.sources.addAll(sources);
              results[key] = installation;
            }
          }
          onProgress?.call(JavaScanProgress(++checked, results.length));
        }
      }

      await Future.wait(List.generate(4, (_) => worker()));
      return results.values.toList()..sort((a, b) {
        final architecture = (a.architecture == platform.arch ? 0 : 1)
            .compareTo(b.architecture == platform.arch ? 0 : 1);
        if (architecture != 0) return architecture;
        final major = b.major.compareTo(a.major);
        return major != 0 ? major : a.executable.compareTo(b.executable);
      });
    } finally {
      _scanning = false;
    }
  }
}
