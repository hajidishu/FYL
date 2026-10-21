import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'network.dart';
import 'accounts.dart';
import 'mod_installer.dart';

const versionManifestUrl =
    'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json';
const javaManifestUrl =
    'https://piston-meta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json';

Future<void> writeJson(File file, Json data) async {
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(data),
    flush: true,
  );
  // Keep a last known good configuration in case the app exits during replacement.
  if (await file.exists()) await file.copy('${file.path}.bak');
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
}

String offlineUuid(String username) {
  final bytes = md5
      .convert(utf8.encode('OfflinePlayer:$username'))
      .bytes
      .toList();
  bytes[6] = (bytes[6] & 0x0f) | 0x30;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String? validateUsername(String username) =>
    RegExp(r'^[A-Za-z0-9_]{3,16}$').hasMatch(username)
    ? null
    : '用户名需要 3–16 位，只能包含英文字母、数字和下划线。';

class LibraryPlan {
  final List<DownloadFile> downloads;
  final List<String> classpath;
  final List<(String, List<String>)> nativeArchives;
  const LibraryPlan(this.downloads, this.classpath, this.nativeArchives);
}

String mavenPath(String coordinate) {
  final extensionParts = coordinate.split('@');
  final parts = extensionParts.first.split(':');
  if (parts.length < 3 || parts.length > 4) {
    throw FormatException('无法解析依赖：$coordinate');
  }
  final version = parts[2];
  final extension = extensionParts.length > 1 ? extensionParts.last : 'jar';
  final classifier = parts.length == 4 ? '-${parts[3]}' : '';
  return '${parts[0].replaceAll('.', '/')}/${parts[1]}/$version/${parts[1]}-$version$classifier.$extension';
}

LibraryPlan planLibraries(Json metadata, String root, HostPlatform platform) {
  final downloads = <DownloadFile>[];
  final classpath = <String>[];
  final natives = <(String, List<String>)>[];
  for (final raw in metadata['libraries'] as List<dynamic>? ?? []) {
    final library = raw as Json;
    if (library['clientreq'] == false ||
        !platform.allows(library['rules'] as List<dynamic>?)) {
      continue;
    }
    final info = library['downloads'] as Json?;
    final artifact = info?['artifact'] as Json?;
    if (artifact != null) {
      final path = safeJoin(
        p.join(root, 'libraries'),
        artifact['path'] as String,
      );
      downloads.add(DownloadFile.fromJson(artifact, path));
      classpath.add(path);
    } else if (info == null && library['natives'] == null) {
      final relative = mavenPath(library['name'] as String);
      final path = safeJoin(p.join(root, 'libraries'), relative);
      downloads.add(
        DownloadFile(
          '${library['url'] ?? 'https://libraries.minecraft.net/'}$relative',
          path,
          hash: library['sha1'] as String?,
          size: library['size'] as int?,
        ),
      );
      classpath.add(path);
    }
    final nativeMap = library['natives'] as Json?;
    if (nativeMap != null && nativeMap[platform.os] != null) {
      final classifier = (nativeMap[platform.os] as String).replaceAll(
        r'${arch}',
        platform.arch == 'x86' ? '32' : '64',
      );
      final native = (info?['classifiers'] as Json?)?[classifier] as Json?;
      if (native == null) {
        throw FormatException(
          '此版本缺少 ${platform.os}/${platform.arch} 的原生库：$classifier',
        );
      }
      final path = safeJoin(
        p.join(root, 'libraries'),
        native['path'] as String,
      );
      downloads.add(DownloadFile.fromJson(native, path));
      natives.add((
        path,
        ((library['extract'] as Json?)?['exclude'] as List<dynamic>? ??
                ['META-INF/'])
            .cast<String>(),
      ));
    }
  }
  return LibraryPlan(downloads, classpath, natives);
}

class MinecraftInstaller {
  final HostPlatform platform;
  final OfficialNetwork network;
  final List<int>? optifineBridge;
  MinecraftInstaller(this.platform, this.network, {this.optifineBridge});

  Future<GameInstance> install(
    InstallTask task,
    CancellationToken token,
    void Function() update, {
    GameInstance? existingInstance,
  }) async {
    if (task.options.validationError != null) {
      throw StateError(task.options.validationError!);
    }
    final settings = task.settings;
    final root = settings.gameRoot;
    final nameError = validateVersionName(
      existingInstance?.name ?? task.instanceName,
    );
    if (nameError != null) throw ArgumentError(nameError);
    final targetDirectory = safeJoin(
      p.join(root, 'versions'),
      task.instanceName,
    );
    if (existingInstance == null &&
        await FileSystemEntity.type(targetDirectory, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError('版本名称“${task.instanceName}”已存在，请使用其他名称。');
    }
    void stage(String text) {
      token.check();
      task.stage = text;
      task.totalFiles = 0;
      task.completedFiles = 0;
      update();
    }

    Future<void> files(List<DownloadFile> files) async {
      task.totalFiles = files.length;
      update();
      await network.downloadAll(
        files,
        token,
        onProgress: (done, total, path) {
          task.completedFiles = done;
          task.totalFiles = total;
          task.detail = p.basename(path);
          update();
        },
        onBytes: (bytes) {
          task.downloadedBytes += bytes;
        },
      );
    }

    stage('获取版本信息');
    final metadata = await network.json(
      task.version.url,
      expectedHash: task.version.sha1,
      token: token,
    );
    if (metadata['downloads']?['client'] == null) {
      throw const FormatException('该历史版本没有可用的官方客户端。');
    }
    final javaMajor =
        (metadata['javaVersion'] as Json?)?['majorVersion'] as int? ?? 8;
    String? java;
    if (settings.automaticJava) {
      stage('准备 Java $javaMajor');
      java = await _runtime(metadata, root, token, stage, files);
    }

    stage('下载客户端与依赖库');
    final version = task.version.id;
    final libraryPlan = planLibraries(metadata, root, platform);
    final downloads = List<DownloadFile>.of(libraryPlan.downloads);
    final cachedClient = safeJoin(
      p.join(root, '.fyl', 'cache', 'clients'),
      '$version.jar',
    );
    downloads.add(
      DownloadFile.fromJson(
        metadata['downloads']['client'] as Json,
        cachedClient,
      ),
    );
    final logging = (metadata['logging'] as Json?)?['client'] as Json?;
    if (logging != null) {
      downloads.add(
        DownloadFile.fromJson(
          logging['file'] as Json,
          safeJoin(
            p.join(root, 'assets', 'log_configs'),
            logging['file']['id'] as String,
          ),
        ),
      );
    }
    final assetInfo = metadata['assetIndex'] as Json?;
    if (assetInfo != null) {
      downloads.add(
        DownloadFile.fromJson(
          assetInfo,
          safeJoin(
            p.join(root, 'assets', 'indexes'),
            '${assetInfo['id']}.json',
          ),
        ),
      );
    }
    await files(downloads);

    if (assetInfo != null) {
      stage('下载游戏资源');
      final index =
          jsonDecode(
                await File(
                  safeJoin(
                    p.join(root, 'assets', 'indexes'),
                    '${assetInfo['id']}.json',
                  ),
                ).readAsString(),
              )
              as Json;
      final assets = <DownloadFile>[];
      for (final asset in (index['objects'] as Json).values) {
        final object = asset as Json;
        final hash = object['hash'] as String;
        if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(hash)) {
          throw const FormatException('资源索引中的哈希无效');
        }
        assets.add(
          DownloadFile(
            'https://resources.download.minecraft.net/${hash.substring(0, 2)}/$hash',
            p.join(root, 'assets', 'objects', hash.substring(0, 2), hash),
            hash: hash,
            size: object['size'] as int,
          ),
        );
      }
      await files(assets);
    }
    stage('完成版本配置');
    final id =
        '${version.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_')}-${DateTime.now().microsecondsSinceEpoch}';
    final instance =
        existingInstance?.copyWith(managedJava: java) ??
        GameInstance(
          id: id,
          name: task.instanceName,
          version: version,
          root: root,
          isolated: settings.isolateVersions,
          javaMajor: javaMajor,
          managedJava: java,
          installation: task.options.toJson(),
        );
    if (existingInstance == null &&
        await Directory(instance.versionDirectory).exists()) {
      throw StateError('版本文件夹已经存在，请使用其他名称。');
    }
    await Directory(instance.versionDirectory).create(recursive: true);
    try {
      await Directory(instance.gameDirectory).create(recursive: true);
      await File(cachedClient).copy(instance.clientJarPath);
      token.check();
      if (task.options.isVanilla) {
        await writeJson(File(instance.metadataPath), {
          ...metadata,
          'id': instance.name,
        });
        return instance;
      }
      return await ModInstaller(
        platform,
        network,
        optifineBridge: optifineBridge,
      ).install(instance, metadata, task, token, update);
    } catch (_) {
      if (existingInstance == null) {
        try {
          final retained = safeJoin(
            p.join(root, '.fyl-trash'),
            'incomplete-${DateTime.now().microsecondsSinceEpoch}-${instance.name}',
          );
          await Directory(retained).parent.create(recursive: true);
          await Directory(instance.versionDirectory).rename(retained);
        } catch (_) {
          /* Preserve the installation error and existing files. */
        }
      }
      rethrow;
    }
  }

  Future<String> _runtime(
    Json metadata,
    String root,
    CancellationToken token,
    void Function(String) stage,
    Future<void> Function(List<DownloadFile>) downloadFiles,
  ) async {
    final component =
        (metadata['javaVersion'] as Json?)?['component'] as String? ??
        'jre-legacy';
    final catalog = await network.json(javaManifestUrl, token: token);
    final entries =
        (catalog[platform.runtimeKey] as Json?)?[component] as List<dynamic>?;
    if (platform.os == 'linux' && platform.arch == 'arm64' ||
        entries == null ||
        entries.isEmpty) {
      throw StateError(
        '官方暂未提供 ${platform.runtimeKey} 的 $component。请在设置中关闭自动 Java，并选择兼容的 Java 可执行文件。',
      );
    }
    final entry = entries.first as Json;
    final descriptor = entry['manifest'] as Json;
    final manifest = await network.json(
      descriptor['url'] as String,
      expectedHash: descriptor['sha1'] as String?,
      token: token,
    );
    final runtimeRoot = p.join(root, 'runtime', platform.runtimeKey, component);
    final files = manifest['files'] as Json;
    final downloads = <DownloadFile>[];
    final executables = <String>[];
    final links = <(String, String)>[];
    for (final entry in files.entries) {
      token.check();
      final file = entry.value as Json;
      final destination = safeJoin(runtimeRoot, entry.key);
      switch (file['type']) {
        case 'directory':
          await Directory(destination).create(recursive: true);
        case 'file':
          downloads.add(
            DownloadFile.fromJson(
              file['downloads']['raw'] as Json,
              destination,
            ),
          );
          if (file['executable'] == true) executables.add(destination);
        case 'link':
          final target = file['target'] as String;
          final resolved = p.normalize(p.join(p.dirname(destination), target));
          if (!p.isWithin(runtimeRoot, resolved)) {
            throw const FormatException('Java 链接越界');
          }
          links.add((destination, target));
      }
    }
    stage('下载官方 Java ${entry['version']['name']}');
    await downloadFiles(downloads);
    token.check();
    if (platform.os != 'windows') {
      for (var i = 0; i < executables.length; i += 50) {
        final batch = executables.skip(i).take(50).toList();
        final result = await Process.run('chmod', ['+x', ...batch]);
        if (result.exitCode != 0) {
          throw StateError('无法设置 Java 执行权限：${result.stderr}');
        }
      }
    }
    for (final (destination, target) in links) {
      token.check();
      final link = Link(destination);
      await Directory(p.dirname(destination)).create(recursive: true);
      if (await FileSystemEntity.type(destination, followLinks: false) ==
          FileSystemEntityType.link) {
        await link.delete();
      }
      await link.create(target);
    }
    // macOS runtime manifests may use a Java bundle instead of a top-level bin directory.
    final candidates = [
      p.join(runtimeRoot, 'bin', platform.javaBinary),
      p.join(
        runtimeRoot,
        'jre.bundle',
        'Contents',
        'Home',
        'bin',
        platform.javaBinary,
      ),
    ];
    for (final candidate in candidates) {
      if (await File(candidate).exists()) return candidate;
    }
    for (final entry in files.keys) {
      if (entry.endsWith('/bin/${platform.javaBinary}')) {
        return safeJoin(runtimeRoot, entry);
      }
    }
    throw StateError('官方 Java 下载完成，但没有找到可执行文件。');
  }
}

List<String> resolveArguments(
  List<dynamic> source,
  HostPlatform platform,
  Map<String, String> variables, {
  Map<String, bool> features = const {},
}) {
  final result = <String>[];
  for (final entry in source) {
    if (entry is String) {
      result.add(entry);
    } else if (entry is Json &&
        platform.allows(entry['rules'] as List<dynamic>?, features: features)) {
      final value = entry['value'];
      if (value is String) {
        result.add(value);
      } else {
        result.addAll((value as List<dynamic>).cast<String>());
      }
    }
  }
  return result
      .map(
        (arg) => arg.replaceAllMapped(RegExp(r'\$\{([^}]+)\}'), (match) {
          final value = variables[match[1]];
          if (value == null) throw FormatException('无法识别的启动参数：${match[0]}');
          return value;
        }),
      )
      .toList();
}

class LaunchCommand {
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  const LaunchCommand(this.executable, this.arguments, this.workingDirectory);
}

LaunchCommand buildLaunchCommand(
  GameInstance instance,
  Json metadata,
  LauncherSettings settings,
  HostPlatform platform,
  String java, {
  GameSession? session,
}) {
  settings = instance.effectiveSettings(settings);
  session ??= GameSession.offline(settings.username.trim());
  final username = session.username;
  final error = validateUsername(username);
  if (error != null) throw ArgumentError(error);
  final libraries = planLibraries(metadata, instance.root, platform);
  final nativeDirectory = p.join(instance.launcherDirectory, 'natives');
  final assetIndex = metadata['assetIndex'] as Json?;
  final variables = <String, String>{
    'auth_player_name': username,
    'auth_uuid': session.uuid,
    'auth_access_token': session.accessToken,
    'auth_session': session.online
        ? 'token:${session.accessToken}:${session.uuid}'
        : '0',
    'user_type': session.online ? 'msa' : 'legacy',
    'user_properties': '{}',
    // NeoForge uses this value to exclude the unpatched client jar by filename.
    'version_name': instance.name,
    'version_type': metadata['type'] as String? ?? 'release',
    'game_directory': instance.gameDirectory,
    'assets_root': p.join(instance.root, 'assets'),
    'assets_index_name': assetIndex?['id'] as String? ?? instance.version,
    'game_assets': p.join(
      instance.root,
      'assets',
      'virtual',
      assetIndex?['id'] as String? ?? 'legacy',
    ),
    'natives_directory': nativeDirectory,
    'launcher_name': 'free_your_launcher',
    'launcher_version': '0.1.0',
    'classpath': [
      ...libraries.classpath,
      instance.clientJarPath,
    ].join(platform.classpathSeparator),
    'classpath_separator': platform.classpathSeparator,
    'library_directory': p.join(instance.root, 'libraries'),
    'resolution_width': '${settings.width}',
    'resolution_height': '${settings.height}',
    'clientid': session.clientId,
    'auth_xuid': session.xuid,
  };
  final features = {'has_custom_resolution': !settings.fullscreen};
  final arguments = metadata['arguments'] as Json?;
  final jvm =
      arguments?['jvm'] as List<dynamic>? ??
      [
        if (platform.os == 'osx') '-XstartOnFirstThread',
        r'-Djava.library.path=${natives_directory}',
        '-cp',
        r'${classpath}',
      ];
  final game =
      arguments?['game'] as List<dynamic>? ??
      splitCommandLine(metadata['minecraftArguments'] as String? ?? '');
  final result = <String>[
    '-Xms${settings.minMemory}M',
    '-Xmx${settings.maxMemory}M',
    ...resolveArguments(jvm, platform, variables, features: features),
    ...splitCommandLine(settings.jvmArguments),
  ];
  final logging = (metadata['logging'] as Json?)?['client'] as Json?;
  if (logging != null) {
    result.add(
      (logging['argument'] as String).replaceAll(
        r'${path}',
        safeJoin(
          p.join(instance.root, 'assets', 'log_configs'),
          logging['file']['id'] as String,
        ),
      ),
    );
  }
  result.add(metadata['mainClass'] as String);
  result.addAll(
    resolveArguments(game, platform, variables, features: features),
  );
  if (settings.fullscreen) result.add('--fullscreen');
  if (arguments == null && !settings.fullscreen) {
    result.addAll([
      '--width',
      '${settings.width}',
      '--height',
      '${settings.height}',
    ]);
  }
  result.addAll(splitCommandLine(settings.gameArguments));
  return LaunchCommand(java, result, instance.gameDirectory);
}

class MinecraftRunner {
  final HostPlatform platform;
  MinecraftRunner(this.platform);

  Future<String> javaFor(
    GameInstance instance,
    LauncherSettings settings,
  ) async {
    final java = instance.javaExecutable(settings);
    if (java.isEmpty) throw StateError('请选择 Java 可执行文件。');
    try {
      final result = await Process.run(java, [
        '-XshowSettings:properties',
        '-version',
      ]).timeout(const Duration(seconds: 15));
      final output = '${result.stdout}\n${result.stderr}';
      if (result.exitCode != 0) throw StateError(output);
      final match = RegExp(
        r'(?:java\.version\s*=\s*|version\s+")([0-9]+)(?:\.([0-9]+))?',
      ).firstMatch(output);
      final major = match == null
          ? null
          : int.parse(match[1] == '1' ? match[2]! : match[1]!);
      if (!instance.launchSettings.skipJavaVersionCheck &&
          (major == null || major < instance.javaMajor)) {
        throw StateError(
          '此版本需要 Java ${instance.javaMajor} 或更高，当前为 ${major ?? '未知版本'}。',
        );
      }
      final javaArch = RegExp(
        r'os\.arch\s*=\s*(\S+)',
      ).firstMatch(output)?.group(1);
      final normalized = switch (javaArch) {
        'amd64' || 'x86_64' => 'x86_64',
        'aarch64' || 'arm64' => 'arm64',
        _ => 'x86',
      };
      if (normalized != platform.arch) {
        throw StateError(
          'Java 的架构 $javaArch 与启动器选择的 ${platform.arch} 原生库不一致，请选择同架构 Java。',
        );
      }
      return java;
    } on ProcessException {
      throw StateError('找不到可用 Java。请在此版本的 Java 设置中选择可用的 Java。');
    }
  }

  Future<LaunchCommand> prepare(
    GameInstance instance,
    LauncherSettings settings, {
    GameSession? session,
  }) async {
    settings = instance.effectiveSettings(settings);
    final usernameError = validateUsername(
      session?.username ?? settings.username.trim(),
    );
    if (usernameError != null) throw ArgumentError(usernameError);
    final settingsError = settings.validate();
    if (settingsError != null) throw ArgumentError(settingsError);
    final metadataFile = File(instance.metadataPath);
    if (!await metadataFile.exists()) {
      throw StateError('版本文件不完整，请在版本设置中补全与修复文件。');
    }
    final metadata = jsonDecode(await metadataFile.readAsString()) as Json;
    final java = await javaFor(instance, settings);
    final plan = planLibraries(metadata, instance.root, platform);
    final verifiable = [
      ...plan.downloads,
      if (metadata['downloads']?['client'] != null)
        DownloadFile.fromJson(
          metadata['downloads']['client'] as Json,
          instance.clientJarPath,
        ),
      if (metadata['assetIndex'] != null)
        DownloadFile.fromJson(
          metadata['assetIndex'] as Json,
          safeJoin(
            p.join(instance.root, 'assets', 'indexes'),
            '${metadata['assetIndex']['id']}.json',
          ),
        ),
    ];
    if (settings.verifyDownloads) {
      for (final file in verifiable) {
        if (!await file.matches(File(file.path))) {
          throw StateError(
            '游戏文件缺失或校验失败：${p.basename(file.path)}。请在版本设置中补全与修复文件。',
          );
        }
      }
    }
    for (final path in [...plan.classpath, instance.clientJarPath]) {
      if (!await File(path).exists()) {
        throw StateError('游戏文件缺失：${p.basename(path)}。请在版本设置中补全与修复文件。');
      }
    }
    final natives = p.join(instance.launcherDirectory, 'natives');
    await Directory(natives).create(recursive: true);
    // Only old metadata uses extraction; modern LWJGL loads native jars from the classpath.
    for (final (archivePath, excluded) in plan.nativeArchives) {
      final archive = ZipDecoder().decodeBytes(
        await File(archivePath).readAsBytes(),
      );
      for (final entry in archive.files) {
        if (!entry.isFile || excluded.any(entry.name.startsWith)) continue;
        final target = safeJoin(natives, entry.name);
        await File(target).parent.create(recursive: true);
        await File(target).writeAsBytes(entry.content);
      }
    }
    if (metadata['assetIndex'] != null) {
      final indexId = metadata['assetIndex']['id'] as String;
      final index =
          jsonDecode(
                await File(
                  safeJoin(
                    p.join(instance.root, 'assets', 'indexes'),
                    '$indexId.json',
                  ),
                ).readAsString(),
              )
              as Json;
      if (index['virtual'] == true || index['map_to_resources'] == true) {
        for (final entry in (index['objects'] as Json).entries) {
          final hash = entry.value['hash'] as String;
          final source = File(
            p.join(
              instance.root,
              'assets',
              'objects',
              hash.substring(0, 2),
              hash,
            ),
          );
          final destinations = [
            if (index['virtual'] == true)
              p.join(instance.root, 'assets', 'virtual', indexId),
            if (index['map_to_resources'] == true)
              p.join(instance.gameDirectory, 'resources'),
          ];
          for (final directory in destinations) {
            final destination = File(safeJoin(directory, entry.key));
            if (!await destination.exists()) {
              await destination.parent.create(recursive: true);
              await source.copy(destination.path);
            }
          }
        }
      }
    }
    return buildLaunchCommand(
      instance,
      metadata,
      settings,
      platform,
      java,
      session: session,
    );
  }
}
