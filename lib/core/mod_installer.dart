import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'install_options.dart';
import 'file_transaction.dart';
import 'minecraft.dart';
import 'mod_catalog.dart';
import 'models.dart';
import 'network.dart';

class ModInstaller {
  final HostPlatform platform;
  final OfficialNetwork network;
  final List<int>? optifineBridge;
  ModInstaller(this.platform, this.network, {this.optifineBridge});

  Future<GameInstance> install(
    GameInstance instance,
    Json vanilla,
    InstallTask task,
    CancellationToken token,
    void Function() update,
  ) async {
    final options = task.options;
    final error = options.validationError;
    if (error != null) throw StateError(error);
    var profile = vanilla;
    void stage(String name) {
      token.check();
      task.stage = name;
      task.completedFiles = 0;
      task.totalFiles = 0;
      update();
    }

    Future<void> download(List<DownloadFile> files) async {
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
          update();
        },
        onCachedBytes: (bytes) {
          task.cachedBytes += bytes;
          update();
        },
      );
    }

    final work = p.join(instance.root, 'installers', 'work', instance.id);
    await Directory(work).create(recursive: true);
    final java = await MinecraftRunner(
      platform,
    ).javaFor(instance, task.settings);
    if (options.loader != null) {
      final loader = options.loader!;
      stage('安装 ${loader.loader.label} ${loader.version}');
      if (loader.loader == ModLoader.fabric ||
          loader.loader == ModLoader.quilt) {
        final catalog = ModCatalog(network);
        final overlay = loader.loader == ModLoader.quilt
            ? await catalog.quiltProfile(
                instance.version,
                loader.version,
                token,
              )
            : await catalog.fabricProfile(
                instance.version,
                loader.version,
                token,
              );
        profile = mergeVersionProfiles(profile, overlay);
        await _libraries(
          profile['libraries'] as List<dynamic>,
          instance.root,
          token,
          download,
        );
      } else {
        profile = await _forge(
          instance,
          profile,
          loader,
          java,
          task,
          work,
          token,
          download,
          update,
        );
      }
    }
    if (options.optifine != null) {
      stage('安装 OptiFine');
      final choice = options.optifine!;
      final installer = safeJoin(
        p.join(instance.root, 'installers'),
        choice.fileName,
      );
      if (choice.localPath != null) {
        if (p.normalize(choice.localPath!) != p.normalize(installer)) {
          await File(choice.localPath!).copy(installer);
        }
      } else {
        final url = await ModCatalog(network).optifineDownload(choice, token);
        await download([DownloadFile(url, installer)]);
      }
      final archive = ZipDecoder().decodeBytes(
        await File(installer).readAsBytes(),
      );
      if (archive.findFile('optifine/Installer.class') == null) {
        throw const FormatException('选择的文件不是有效的 OptiFine 安装器。');
      }
      if (options.loader != null) {
        final mods = Directory(p.join(work, 'mods'));
        await mods.create(recursive: true);
        await File(installer).copy(safeJoin(mods.path, choice.fileName));
        if (options.fabricOptifine) {
          final bridge = options.optifabric!;
          final destination = safeJoin(mods.path, bridge.fileName);
          if (bridge.localPath != null) {
            await File(bridge.localPath!).copy(destination);
          } else {
            await download([
              DownloadFile(
                bridge.url,
                destination,
                hash: bridge.sha1,
                size: bridge.size,
              ),
            ]);
          }
          final compatibility = ZipDecoder().decodeBytes(
            await File(destination).readAsBytes(),
          );
          final descriptor = compatibility.findFile('fabric.mod.json');
          if (descriptor == null ||
              (jsonDecode(utf8.decode(descriptor.content)) as Json)['id'] !=
                  'optifabric') {
            throw const FormatException('选择的兼容模组不是有效的 OptiFabric。');
          }
        }
      } else {
        if (optifineBridge == null) throw StateError('缺少 OptiFine 安装桥接组件。');
        final scratch = p.join(work, 'optifine');
        final baseDirectory = p.join(scratch, 'versions', instance.version);
        await Directory(baseDirectory).create(recursive: true);
        await File(
          instance.clientJarPath,
        ).copy(p.join(baseDirectory, '${instance.version}.jar'));
        await writeJson(
          File(p.join(baseDirectory, '${instance.version}.json')),
          vanilla,
        );
        await writeJson(File(p.join(scratch, 'launcher_profiles.json')), {
          'profiles': <String, dynamic>{},
          'settings': <String, dynamic>{},
        });
        final helperDirectory = Directory(p.join(work, 'bridge'));
        await helperDirectory.create(recursive: true);
        await File(
          p.join(helperDirectory.path, 'FylOptiFineBridge.class'),
        ).writeAsBytes(optifineBridge!);
        await _java(
          java,
          [
            '-Djava.awt.headless=true',
            '-cp',
            [helperDirectory.path, installer].join(platform.classpathSeparator),
            'FylOptiFineBridge',
            scratch,
          ],
          work,
          task,
          token,
          update,
        );
        Json? overlay;
        await for (final entry in Directory(
          p.join(scratch, 'versions'),
        ).list(recursive: true)) {
          if (entry is File &&
              entry.path.endsWith('.json') &&
              p.dirname(entry.path) != baseDirectory) {
            overlay = jsonDecode(await entry.readAsString()) as Json;
          }
        }
        if (overlay == null) throw StateError('OptiFine 安装器未生成启动配置。');
        await _copyTree(
          p.join(scratch, 'libraries'),
          p.join(instance.root, 'libraries'),
          token,
        );
        profile = mergeVersionProfiles(profile, overlay);
        await _libraries(
          profile['libraries'] as List<dynamic>,
          instance.root,
          token,
          download,
        );
      }
    }
    token.check();
    // Validate every add-on before changing an existing shared mods directory.
    await _copyTree(
      p.join(work, 'mods'),
      p.join(instance.gameDirectory, 'mods'),
      token,
    );
    profile['id'] = instance.name;
    profile.remove('jar');
    await writeJson(File(instance.metadataPath), profile);
    return instance.copyWith(
      components: options.summary,
      installation: options.toJson(),
    );
  }

  Future<void> _copyTree(
    String source,
    String destination,
    CancellationToken token,
  ) async {
    if (!await Directory(source).exists()) return;
    final copies = <(String, String)>[];
    await for (final entity in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      token.check();
      if (entity is! File) continue;
      copies.add((
        entity.path,
        safeJoin(destination, p.relative(entity.path, from: source)),
      ));
    }
    await publishFiles(destination, copies, token);
  }

  Future<void> _libraries(
    List<dynamic> libraries,
    String root,
    CancellationToken token,
    Future<void> Function(List<DownloadFile>) download, {
    Archive? installer,
  }) async {
    final files = <DownloadFile>[];
    for (final raw in libraries) {
      token.check();
      final library = raw as Json;
      if (library['clientreq'] == false ||
          !platform.allows(library['rules'] as List<dynamic>?)) {
        continue;
      }
      final artifact = (library['downloads'] as Json?)?['artifact'] as Json?;
      final relative =
          artifact?['path'] as String? ?? mavenPath(library['name'] as String);
      final destination = safeJoin(p.join(root, 'libraries'), relative);
      final embedded = installer?.findFile('maven/$relative');
      if (embedded != null) {
        await File(destination).parent.create(recursive: true);
        await File(destination).writeAsBytes(embedded.content);
      }
      String url;
      if (artifact != null) {
        url = artifact['url'] as String? ?? '';
      } else {
        var base =
            library['url'] as String? ?? 'https://libraries.minecraft.net/';
        if (!base.endsWith('/')) base = '$base/';
        url = '$base$relative';
        library['url'] = base;
      }
      if (url.startsWith('http://')) {
        url = url.replaceFirst('http://', 'https://');
      }
      if (artifact != null && url.isNotEmpty) artifact['url'] = url;
      if (url.isEmpty ||
          embedded != null ||
          artifact == null && await File(destination).exists()) {
        continue;
      }
      files.add(
        DownloadFile(
          url,
          destination,
          hash: artifact?['sha1'] as String? ?? library['sha1'] as String?,
          size: artifact?['size'] as int? ?? library['size'] as int?,
        ),
      );
    }
    await download(files);
  }

  Future<Json> _forge(
    GameInstance instance,
    Json vanilla,
    LoaderVersion loader,
    String java,
    InstallTask task,
    String work,
    CancellationToken token,
    Future<void> Function(List<DownloadFile>) download,
    void Function() update,
  ) async {
    final url = loader.installerUrl!;
    String? checksum;
    try {
      checksum = RegExp(r'[a-fA-F0-9]{40}')
          .firstMatch(await network.text('$url.sha1', token: token))
          ?.group(0)
          ?.toLowerCase();
    } on Cancelled {
      rethrow;
    } catch (_) {
      /* Some historical Maven artifacts have no checksum sidecar. */
    }
    final installerPath = safeJoin(
      p.join(instance.root, 'installers'),
      Uri.parse(url).pathSegments.last,
    );
    await download([DownloadFile(url, installerPath, hash: checksum)]);
    final archive = ZipDecoder().decodeBytes(
      await File(installerPath).readAsBytes(),
    );
    final installFile = archive.findFile('install_profile.json');
    if (installFile == null) throw StateError('该安装器没有可用的客户端安装清单。');
    final install = jsonDecode(utf8.decode(installFile.content)) as Json;
    Json overlay;
    if (install['versionInfo'] is Json) {
      overlay = install['versionInfo'] as Json;
      final embeddedInfo = install['install'] as Json?;
      if (embeddedInfo?['filePath'] != null && embeddedInfo?['path'] != null) {
        final embedded = archive.findFile(embeddedInfo!['filePath'] as String);
        if (embedded == null) throw StateError('旧版 Forge 安装器缺少 universal 文件。');
        final destination = File(
          safeJoin(
            p.join(instance.root, 'libraries'),
            mavenPath(embeddedInfo['path'] as String),
          ),
        );
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(embedded.content);
      }
    } else {
      final name = (install['json'] as String? ?? 'version.json').replaceFirst(
        RegExp(r'^/'),
        '',
      );
      final entry = archive.findFile(name);
      if (entry == null) throw StateError('安装器缺少版本启动配置。');
      overlay = jsonDecode(utf8.decode(entry.content)) as Json;
    }
    final result = mergeVersionProfiles(vanilla, overlay);
    task.stage = '下载 ${loader.loader.label} 依赖';
    update();
    await _libraries(
      [
        ...?install['libraries'] as List<dynamic>?,
        ...?result['libraries'] as List<dynamic>?,
      ],
      instance.root,
      token,
      download,
      installer: archive,
    );
    final variables = <String, String>{
      'SIDE': 'client',
      'ROOT': instance.root,
      'MINECRAFT_VERSION': instance.version,
      'MINECRAFT_JAR': instance.clientJarPath,
      'INSTALLER': installerPath,
      'LIBRARY_DIR': p.join(instance.root, 'libraries'),
    };
    final data = install['data'] as Json? ?? {};
    String resolve(String value, [Set<String> trail = const {}]) {
      if (value.startsWith("'") && value.endsWith("'")) {
        return value.substring(1, value.length - 1);
      }
      if (value.startsWith('[') && value.endsWith(']')) {
        return safeJoin(
          p.join(instance.root, 'libraries'),
          mavenPath(value.substring(1, value.length - 1)),
        );
      }
      if (value.startsWith('/')) {
        final entry = archive.findFile(value.substring(1));
        if (entry != null) {
          final destination = File(safeJoin(work, value.substring(1)));
          destination.parent.createSync(recursive: true);
          destination.writeAsBytesSync(entry.content);
          return destination.path;
        }
      }
      return value.replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
        final key = match[1]!;
        if (variables.containsKey(key)) return variables[key]!;
        if (trail.contains(key) || !data.containsKey(key)) {
          throw FormatException('无法解析安装器参数：$key');
        }
        final entry = data[key];
        final raw = entry is Json ? entry['client'] as String : entry as String;
        return resolve(raw, {...trail, key});
      });
    }

    final processors = (install['processors'] as List<dynamic>? ?? [])
        .cast<Json>()
        .where(
          (item) =>
              item['sides'] == null ||
              (item['sides'] as List).contains('client'),
        )
        .toList();
    for (var index = 0; index < processors.length; index++) {
      token.check();
      final processor = processors[index];
      final outputs = processor['outputs'] as Json? ?? {};
      Future<bool> outputsValid() async {
        if (outputs.isEmpty) return false;
        for (final entry in outputs.entries) {
          final file = File(resolve(entry.key));
          final expected = resolve(entry.value as String);
          if (!await file.exists() ||
              !RegExp(r'^[a-f0-9]{40}$').hasMatch(expected) ||
              (await sha1.bind(file.openRead()).first).toString() != expected) {
            return false;
          }
        }
        return true;
      }

      if (await outputsValid()) continue;
      final processorPath = safeJoin(
        p.join(instance.root, 'libraries'),
        mavenPath(processor['jar'] as String),
      );
      final jar = ZipDecoder().decodeBytes(
        await File(processorPath).readAsBytes(),
      );
      final manifest = jar.findFile('META-INF/MANIFEST.MF');
      final unfolded = manifest == null
          ? ''
          : utf8.decode(manifest.content).replaceAll(RegExp(r'\r?\n '), '');
      final main = RegExp(
        r'^Main-Class:\s*(.+?)\s*$',
        multiLine: true,
      ).firstMatch(unfolded)?.group(1);
      if (main == null) {
        throw StateError('安装处理器没有 Main-Class：${processor['jar']}');
      }
      final classpath = {
        processorPath,
        for (final name in processor['classpath'] as List<dynamic>? ?? [])
          safeJoin(
            p.join(instance.root, 'libraries'),
            mavenPath(name as String),
          ),
      }.join(platform.classpathSeparator);
      for (final entry in outputs.keys) {
        await File(resolve(entry)).parent.create(recursive: true);
      }
      task.stage =
          '处理 ${loader.loader.label} 客户端补丁 ${index + 1}/${processors.length}';
      task.totalFiles = processors.length;
      task.completedFiles = index;
      update();
      await _java(
        java,
        [
          '-Xmx${task.settings.maxMemory}M',
          '-Djava.awt.headless=true',
          '-cp',
          classpath,
          main,
          for (final arg in processor['args'] as List<dynamic>? ?? [])
            resolve(arg as String),
        ],
        work,
        task,
        token,
        update,
      );
      if (outputs.isNotEmpty && !await outputsValid()) {
        throw StateError('安装处理器输出文件校验失败：${processor['jar']}');
      }
    }
    return result;
  }

  Future<void> _java(
    String executable,
    List<String> args,
    String work,
    InstallTask task,
    CancellationToken token,
    void Function() update,
  ) async {
    token.check();
    final process = await Process.start(
      executable,
      args,
      workingDirectory: work,
      runInShell: false,
    );
    void kill() => process.kill();
    token.add(kill);
    final tail = <String>[];
    final log = File(
      p.join(work, 'install.log'),
    ).openWrite(mode: FileMode.append);
    void line(String text) {
      log.writeln(text);
      tail.add(text);
      if (tail.length > 24) tail.removeAt(0);
      task.detail = text.length > 220 ? text.substring(0, 220) : text;
      update();
    }

    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(line);
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(line);
    try {
      final code = await process.exitCode.timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          process.kill();
          throw TimeoutException('客户端安装处理超时');
        },
      );
      await Future.wait([output, errors]);
      token.check();
      if (code != 0) throw StateError('组件安装失败（退出码 $code）：\n${tail.join('\n')}');
    } finally {
      token.remove(kill);
      await log.close();
    }
  }
}
