import 'dart:io';

import 'package:path/path.dart' as p;
import 'install_options.dart';

typedef Json = Map<String, dynamic>;

class LauncherSettings {
  static const defaultMicrosoftClientId =
      '91d04d35-a673-4844-b00b-7f3838bd2fff';

  static String resolveMicrosoftClientId(String? value) {
    final clientId = value?.trim() ?? '';
    return clientId.isEmpty ? defaultMicrosoftClientId : clientId;
  }

  String gameRoot;
  String username;
  bool isolateVersions;
  bool automaticJava;
  String javaPath;
  int minMemory;
  int maxMemory;
  int width;
  int height;
  bool fullscreen;
  String jvmArguments;
  String gameArguments;
  String preLaunchCommand;
  int parallelDownloads;
  int downloadRetries;
  int timeoutSeconds;
  bool verifyDownloads;
  bool showSnapshots;
  bool showHistorical;
  bool minimizeOnLaunch;
  String theme;
  String microsoftClientId;
  String curseforgeApiKey;

  LauncherSettings({
    required this.gameRoot,
    this.username = '',
    this.isolateVersions = true,
    this.automaticJava = true,
    this.javaPath = '',
    this.minMemory = 512,
    this.maxMemory = 2048,
    this.width = 1280,
    this.height = 720,
    this.fullscreen = false,
    this.jvmArguments = '',
    this.gameArguments = '',
    this.preLaunchCommand = '',
    this.parallelDownloads = 6,
    this.downloadRetries = 2,
    this.timeoutSeconds = 30,
    this.verifyDownloads = true,
    this.showSnapshots = false,
    this.showHistorical = false,
    this.minimizeOnLaunch = false,
    this.theme = 'dark',
    this.microsoftClientId = defaultMicrosoftClientId,
    this.curseforgeApiKey = const String.fromEnvironment(
      'FYL_CURSEFORGE_API_KEY',
    ),
  });

  factory LauncherSettings.fromJson(Json json, String defaultRoot) =>
      LauncherSettings(
        gameRoot: json['gameRoot'] as String? ?? defaultRoot,
        username: json['username'] as String? ?? '',
        isolateVersions: json['isolateVersions'] as bool? ?? true,
        automaticJava: json['automaticJava'] as bool? ?? true,
        javaPath: json['javaPath'] as String? ?? '',
        minMemory: json['minMemory'] as int? ?? 512,
        maxMemory: json['maxMemory'] as int? ?? 2048,
        width: json['width'] as int? ?? 1280,
        height: json['height'] as int? ?? 720,
        fullscreen: json['fullscreen'] as bool? ?? false,
        jvmArguments: json['jvmArguments'] as String? ?? '',
        gameArguments: json['gameArguments'] as String? ?? '',
        preLaunchCommand: json['preLaunchCommand'] as String? ?? '',
        parallelDownloads: json['parallelDownloads'] as int? ?? 6,
        downloadRetries: json['downloadRetries'] as int? ?? 2,
        timeoutSeconds: json['timeoutSeconds'] as int? ?? 30,
        verifyDownloads: json['verifyDownloads'] as bool? ?? true,
        showSnapshots: json['showSnapshots'] as bool? ?? false,
        showHistorical: json['showHistorical'] as bool? ?? false,
        minimizeOnLaunch: json['minimizeOnLaunch'] as bool? ?? false,
        theme: json['theme'] as String? ?? 'dark',
        microsoftClientId: resolveMicrosoftClientId(
          json['microsoftClientId'] as String?,
        ),
      );

  Json toJson() => {
    'gameRoot': gameRoot,
    'username': username,
    'isolateVersions': isolateVersions,
    'automaticJava': automaticJava,
    'javaPath': javaPath,
    'minMemory': minMemory,
    'maxMemory': maxMemory,
    'width': width,
    'height': height,
    'fullscreen': fullscreen,
    'jvmArguments': jvmArguments,
    'gameArguments': gameArguments,
    'preLaunchCommand': preLaunchCommand,
    'parallelDownloads': parallelDownloads,
    'downloadRetries': downloadRetries,
    'timeoutSeconds': timeoutSeconds,
    'verifyDownloads': verifyDownloads,
    'showSnapshots': showSnapshots,
    'showHistorical': showHistorical,
    'minimizeOnLaunch': minimizeOnLaunch,
    'theme': theme,
    'microsoftClientId': microsoftClientId,
  };

  LauncherSettings copy() =>
      LauncherSettings.fromJson(toJson(), gameRoot)
        ..curseforgeApiKey = curseforgeApiKey;

  String? validate() {
    if (!p.isAbsolute(gameRoot.trim())) return '游戏根目录需要使用绝对路径。';
    if (minMemory < 256 || maxMemory < minMemory || maxMemory > 131072) {
      return '内存需要在 256–131072 MB 之间，最大内存不能小于初始内存。';
    }
    if (width < 640 || width > 16384 || height < 360 || height > 16384) {
      return '窗口宽度范围为 640–16384，高度范围为 360–16384。';
    }
    if (parallelDownloads < 1 || parallelDownloads > 16) {
      return '并行下载数需要在 1–16 之间。';
    }
    if (downloadRetries < 0 || downloadRetries > 5) return '重试次数需要在 0–5 之间。';
    if (timeoutSeconds < 5 || timeoutSeconds > 300) return '下载超时需要在 5–300 秒之间。';
    if (!automaticJava && javaPath.trim().isEmpty) return '请选择 Java 可执行文件。';
    try {
      splitCommandLine(jvmArguments);
      splitCommandLine(gameArguments);
    } on FormatException {
      return '额外启动参数的引号没有闭合。';
    }
    return null;
  }
}

enum InstanceJavaMode { inherit, automatic, custom }

String? validateVersionName(String name) {
  if (name.isEmpty ||
      name.length > 100 ||
      name != name.trim() ||
      name == '.' ||
      name == '..' ||
      name.endsWith('.') ||
      RegExp(r'[<>:"/\\|?*;,\x00-\x1f]').hasMatch(name) ||
      RegExp(
        r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(name)) {
    return '版本名称需要为 1–100 个字符，不能包含路径分隔符、特殊符号或系统保留名称。';
  }
  return null;
}

class InstanceLaunchSettings {
  final int? minMemory, maxMemory, width, height;
  final bool? fullscreen, minimizeOnLaunch, verifyDownloads;
  final String? jvmArguments, gameArguments, preLaunchCommand;
  final bool skipJavaVersionCheck;
  const InstanceLaunchSettings({
    this.minMemory,
    this.maxMemory,
    this.width,
    this.height,
    this.fullscreen,
    this.minimizeOnLaunch,
    this.verifyDownloads,
    this.jvmArguments,
    this.gameArguments,
    this.preLaunchCommand,
    this.skipJavaVersionCheck = false,
  });
  factory InstanceLaunchSettings.fromJson(Json j) => InstanceLaunchSettings(
    minMemory: j['minMemory'] as int?,
    maxMemory: j['maxMemory'] as int?,
    width: j['width'] as int?,
    height: j['height'] as int?,
    fullscreen: j['fullscreen'] as bool?,
    minimizeOnLaunch: j['minimizeOnLaunch'] as bool?,
    verifyDownloads: j['verifyDownloads'] as bool?,
    jvmArguments: j['jvmArguments'] as String?,
    gameArguments: j['gameArguments'] as String?,
    preLaunchCommand: j['preLaunchCommand'] as String?,
    skipJavaVersionCheck: j['skipJavaVersionCheck'] == true,
  );
  Json toJson() => {
    'minMemory': minMemory,
    'maxMemory': maxMemory,
    'width': width,
    'height': height,
    'fullscreen': fullscreen,
    'minimizeOnLaunch': minimizeOnLaunch,
    'verifyDownloads': verifyDownloads,
    'jvmArguments': jvmArguments,
    'gameArguments': gameArguments,
    'preLaunchCommand': preLaunchCommand,
    'skipJavaVersionCheck': skipJavaVersionCheck,
  };
  LauncherSettings apply(LauncherSettings defaults) => defaults.copy()
    ..minMemory = minMemory ?? defaults.minMemory
    ..maxMemory = maxMemory ?? defaults.maxMemory
    ..width = width ?? defaults.width
    ..height = height ?? defaults.height
    ..fullscreen = fullscreen ?? defaults.fullscreen
    ..minimizeOnLaunch = minimizeOnLaunch ?? defaults.minimizeOnLaunch
    ..verifyDownloads = verifyDownloads ?? defaults.verifyDownloads
    ..jvmArguments = jvmArguments ?? defaults.jvmArguments
    ..gameArguments = gameArguments ?? defaults.gameArguments
    ..preLaunchCommand = preLaunchCommand ?? defaults.preLaunchCommand;
}

class GameInstance {
  final String id;
  final String name;
  final String version;
  final String root;
  final bool isolated;
  final int javaMajor;
  final String? managedJava;
  final String components;
  final InstanceJavaMode javaMode;
  final String javaPath;
  final String description, category, icon;
  final bool favorite;
  final InstanceLaunchSettings launchSettings;
  final Json installation;
  final DateTime createdAt;

  GameInstance({
    required this.id,
    required this.name,
    required this.version,
    required this.root,
    required this.isolated,
    required this.javaMajor,
    this.managedJava,
    this.components = '',
    this.javaMode = InstanceJavaMode.inherit,
    this.javaPath = '',
    this.description = '',
    this.category = '',
    this.icon = 'auto',
    this.favorite = false,
    this.launchSettings = const InstanceLaunchSettings(),
    this.installation = const {},
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  String get versionDirectory => safeJoin(p.join(root, 'versions'), name);
  String get gameDirectory => isolated ? versionDirectory : root;
  String get metadataPath => safeJoin(versionDirectory, '$name.json');
  String get clientJarPath => safeJoin(versionDirectory, '$name.jar');
  String get launcherDirectory => p.join(versionDirectory, '.fyl');

  String javaExecutable(LauncherSettings defaults) => switch (javaMode) {
    InstanceJavaMode.custom => javaPath.trim(),
    InstanceJavaMode.automatic => managedJava ?? 'java',
    InstanceJavaMode.inherit =>
      defaults.automaticJava ? managedJava ?? 'java' : defaults.javaPath.trim(),
  };

  LauncherSettings effectiveSettings(LauncherSettings defaults) {
    final result = launchSettings.apply(defaults);
    if (javaMode != InstanceJavaMode.inherit) {
      result.automaticJava = javaMode == InstanceJavaMode.automatic;
      result.javaPath = javaPath;
    }
    return result;
  }

  GameInstance withJava(InstanceJavaMode mode, String path) =>
      copyWith(javaMode: mode, javaPath: path.trim());
  GameInstance copyWith({
    String? name,
    String? description,
    String? category,
    String? icon,
    bool? favorite,
    bool? isolated,
    String? managedJava,
    String? components,
    InstanceJavaMode? javaMode,
    String? javaPath,
    InstanceLaunchSettings? launchSettings,
    Json? installation,
  }) => GameInstance(
    id: id,
    name: name ?? this.name,
    version: version,
    root: root,
    isolated: isolated ?? this.isolated,
    javaMajor: javaMajor,
    managedJava: managedJava ?? this.managedJava,
    components: components ?? this.components,
    javaMode: javaMode ?? this.javaMode,
    javaPath: javaPath ?? this.javaPath,
    description: description ?? this.description,
    category: category ?? this.category,
    icon: icon ?? this.icon,
    favorite: favorite ?? this.favorite,
    launchSettings: launchSettings ?? this.launchSettings,
    installation: installation ?? this.installation,
    createdAt: createdAt,
  );
  factory GameInstance.fromJson(Json j) => GameInstance(
    id: j['id'] as String,
    name: j['name'] as String,
    version: j['version'] as String,
    root: j['root'] as String,
    isolated: j['isolated'] as bool,
    javaMajor: j['javaMajor'] as int? ?? 8,
    managedJava: j['managedJava'] as String?,
    components: j['components'] as String? ?? '',
    javaMode: InstanceJavaMode.values.firstWhere(
      (mode) => mode.name == j['javaMode'],
      orElse: () => InstanceJavaMode.inherit,
    ),
    javaPath: j['javaPath'] as String? ?? '',
    description: j['description'] as String? ?? '',
    category: j['category'] as String? ?? '',
    icon: j['icon'] as String? ?? 'auto',
    favorite: j['favorite'] == true,
    launchSettings: InstanceLaunchSettings.fromJson(
      j['launchSettings'] as Json? ?? {},
    ),
    installation: j['installation'] as Json? ?? {},
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
  );
  Json toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'root': root,
    'isolated': isolated,
    'javaMajor': javaMajor,
    'managedJava': managedJava,
    'components': components,
    'javaMode': javaMode.name,
    'javaPath': javaPath,
    'description': description,
    'category': category,
    'icon': icon,
    'favorite': favorite,
    'launchSettings': launchSettings.toJson(),
    'installation': installation,
    'createdAt': createdAt.toIso8601String(),
  };
}

class MinecraftVersion {
  final String id;
  final String type;
  final String url;
  final String? sha1;
  final DateTime released;
  MinecraftVersion.fromJson(Json j)
    : id = j['id'] as String,
      type = j['type'] as String,
      url = j['url'] as String,
      sha1 = j['sha1'] as String?,
      released = DateTime.parse(j['releaseTime'] as String);
}

enum TaskStatus { running, completed, cancelled, failed }

class InstallTask {
  final MinecraftVersion version;
  final String instanceName;
  final LauncherSettings settings;
  final InstallOptions options;
  TaskStatus status = TaskStatus.running;
  String stage = '准备安装';
  String detail = '';
  int completedFiles = 0;
  int totalFiles = 0;
  int downloadedBytes = 0;
  String? error;
  InstallTask(
    this.version,
    this.instanceName,
    this.settings, {
    this.options = const InstallOptions(),
  });
  double? get progress => totalFiles == 0 ? null : completedFiles / totalFiles;
}

/// Parse an argument list without a shell; backslashes in Windows paths are preserved.
List<String> splitCommandLine(String input) {
  final result = <String>[];
  final buffer = StringBuffer();
  String? quote;
  var started = false;
  for (final char in input.split('')) {
    if (char == quote) {
      quote = null;
      started = true;
    } else if (quote == null && (char == '"' || char == "'")) {
      quote = char;
      started = true;
    } else if (quote == null && char.trim().isEmpty) {
      if (started) {
        result.add(buffer.toString());
        buffer.clear();
        started = false;
      }
    } else {
      buffer.write(char);
      started = true;
    }
  }
  if (quote != null) throw const FormatException('Unclosed quote');
  if (started) result.add(buffer.toString());
  return result;
}

class HostPlatform {
  final String os;
  final String arch;
  final String osVersion;
  const HostPlatform(this.os, this.arch, [this.osVersion = '']);

  static Future<HostPlatform> detect() async {
    String arch;
    if (Platform.isWindows) {
      arch =
          (Platform.environment['PROCESSOR_ARCHITEW6432'] ??
                  Platform.environment['PROCESSOR_ARCHITECTURE'] ??
                  'AMD64')
              .toLowerCase();
    } else {
      arch = (await Process.run('uname', ['-m'])).stdout.toString().trim();
    }
    arch = switch (arch) {
      'amd64' || 'x86_64' => 'x86_64',
      'aarch64' || 'arm64' => 'arm64',
      _ => 'x86',
    };
    final String osVersion;
    if (Platform.isWindows) {
      osVersion =
          RegExp(
            r'\d+\.\d+(?:\.\d+)*',
          ).allMatches(Platform.operatingSystemVersion).lastOrNull?.group(0) ??
          '';
    } else {
      final result = await Process.run(Platform.isMacOS ? 'sw_vers' : 'uname', [
        Platform.isMacOS ? '-productVersion' : '-r',
      ]);
      osVersion = result.stdout.toString().trim();
    }
    return HostPlatform(
      Platform.isWindows
          ? 'windows'
          : Platform.isMacOS
          ? 'osx'
          : 'linux',
      arch,
      osVersion,
    );
  }

  String get runtimeKey => switch (os) {
    'windows' =>
      arch == 'arm64'
          ? 'windows-arm64'
          : arch == 'x86'
          ? 'windows-x86'
          : 'windows-x64',
    'osx' => arch == 'arm64' ? 'mac-os-arm64' : 'mac-os',
    _ => arch == 'x86' ? 'linux-i386' : 'linux',
  };
  String get javaBinary => os == 'windows' ? 'java.exe' : 'java';
  String get classpathSeparator => os == 'windows' ? ';' : ':';

  bool allows(List<dynamic>? rules, {Map<String, bool> features = const {}}) {
    if (rules == null || rules.isEmpty) return true;
    var allowed = false;
    for (final item in rules) {
      final rule = item as Json;
      final target = rule['os'] as Json?;
      if (target != null) {
        if (target['name'] != null && target['name'] != os) continue;
        if (target['arch'] != null) {
          final wanted = target['arch'] as String;
          final aliases = arch == 'x86_64'
              ? ['x86_64', 'amd64']
              : arch == 'arm64'
              ? ['arm64', 'aarch64']
              : ['x86', 'i386'];
          if (!aliases.any((a) => RegExp('^(?:$wanted)\$').hasMatch(a))) {
            continue;
          }
        }
        if (target['version'] != null &&
            !RegExp(target['version'] as String).hasMatch(osVersion)) {
          continue;
        }
      }
      final requiredFeatures = rule['features'] as Json?;
      if (requiredFeatures != null &&
          requiredFeatures.entries.any(
            (e) => (features[e.key] ?? false) != e.value,
          )) {
        continue;
      }
      allowed = rule['action'] == 'allow';
    }
    return allowed;
  }
}

/// Metadata and archives must never escape the launcher's selected root.
String safeJoin(String root, String relative) {
  final normalized = relative.replaceAll('\\', '/');
  if (p.posix.isAbsolute(normalized) ||
      RegExp(r'^[a-zA-Z]:').hasMatch(normalized) ||
      normalized.split('/').contains('..')) {
    throw FormatException('文件路径无效：$relative');
  }
  final target = p.normalize(p.join(root, p.joinAll(normalized.split('/'))));
  if (!p.isWithin(p.normalize(root), target)) {
    throw FormatException('文件路径越界：$relative');
  }
  return target;
}
