import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:free_your_launcher/core/install_options.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/mod_catalog.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final kind = arguments.firstOrNull ?? 'fabric';
  final minecraft =
      arguments
          .where((item) => item.startsWith('--mc='))
          .firstOrNull
          ?.substring(5) ??
      '1.21.1';
  final root = p.join(Directory.current.path, 'build', 'smoke-data');
  final settings = LauncherSettings(
    gameRoot: root,
    username: 'Launcher_Test',
    parallelDownloads: 12,
    isolateVersions: !arguments.contains('--shared'),
  );
  final recordName = arguments.contains('--shared') ? '$kind-shared' : kind;
  final platform = await HostPlatform.detect();
  final network = OfficialNetwork(settings);
  final token = CancellationToken();
  try {
    final catalog = ModCatalog(network);
    InstallOptions options;
    if (kind == 'fabric-optifine') {
      final loaders = await catalog.loaders(ModLoader.fabric, minecraft, token);
      final optifines = await catalog.optifine(minecraft, token);
      final bridges = await catalog.optifabric(minecraft, token);
      options = InstallOptions(
        loader: loaders.firstWhere((item) => item.version == '0.15.11'),
        optifine: optifines.firstWhere(
          (item) => item.fileName == 'OptiFine_1.20.1_HD_U_I6.jar',
        ),
        optifabric: bridges.first,
      );
    } else if (kind == 'optifine') {
      final versions = await catalog.optifine(minecraft, token);
      options = InstallOptions(optifine: versions.first);
    } else {
      final loader = ModLoader.values.byName(kind);
      final choices = await catalog.loaders(loader, minecraft, token);
      options = InstallOptions(
        loader: choices.firstWhere(
          (item) => item.stable,
          orElse: () => choices.first,
        ),
      );
    }
    stdout.writeln('SELECTED ${options.summary}');
    final manifest = await network.json(versionManifestUrl);
    final version = (manifest['versions'] as List<dynamic>)
        .map((item) => MinecraftVersion.fromJson(item as Json))
        .firstWhere((item) => item.id == minecraft);
    final task = InstallTask(
      version,
      arguments
              .where((arg) => arg.startsWith('--name='))
              .firstOrNull
              ?.substring(7) ??
          'Smoke $kind $minecraft${arguments.contains('--shared') ? ' shared' : ''}',
      settings,
      options: options,
    );
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    final instance = arguments.contains('--reuse')
        ? GameInstance.fromJson(
            jsonDecode(
                  await File(
                    p.join(root, '$recordName-instance.json'),
                  ).readAsString(),
                )
                as Json,
          )
        : await MinecraftInstaller(
            platform,
            network,
            optifineBridge: kind == 'optifine'
                ? await File(
                    'assets/java/FylOptiFineBridge.class',
                  ).readAsBytes()
                : null,
          ).install(task, token, () {
            final now = DateTime.now();
            if (now.difference(last).inSeconds >= 2) {
              stdout.writeln(
                '${task.stage} ${task.completedFiles}/${task.totalFiles} ${task.detail}',
              );
              last = now;
            }
          });
    await writeJson(
      File(p.join(root, '$recordName-instance.json')),
      instance.toJson(),
    );
    final command = await MinecraftRunner(platform).prepare(instance, settings);
    stdout.writeln(
      'INSTALL_OK ${instance.components} / ${instance.metadataPath}',
    );
    if (arguments.contains('--launch')) {
      final process = await Process.start(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
      );
      final log = File(p.join(root, '$kind-game.log')).openWrite();
      final ready = Completer<bool>();
      var initialized = false;
      void line(String text) {
        log.writeln(text);
        if (text.contains('OpenAL initialized') ||
            text.contains('Sound engine started')) {
          initialized = true;
          if (!ready.isCompleted) ready.complete(true);
        }
        stdout.writeln(text);
      }

      final output = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach(line);
      final errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach(line);
      await Future.any([
        process.exitCode.then((_) => false),
        ready.future,
      ]).timeout(const Duration(seconds: 100), onTimeout: () => false);
      if (initialized) await Future<void>.delayed(const Duration(seconds: 3));
      process.kill();
      await process.exitCode;
      await Future.wait([output, errors]);
      await log.close();
      stdout.writeln('GAME_INITIALIZED=$initialized');
      if (!instance.isolated) {
        final inRoot = await File(
          p.join(instance.root, 'logs', 'latest.log'),
        ).exists();
        final inVersion = await Directory(
          p.join(instance.versionDirectory, 'logs'),
        ).exists();
        stdout.writeln(
          'SHARED_LAYOUT_OK=${inRoot && !inVersion && command.workingDirectory == instance.root}',
        );
        if (!inRoot || inVersion || command.workingDirectory != instance.root) {
          exitCode = 1;
        }
      }
      if (!initialized) exitCode = 1;
    }
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  } finally {
    network.close();
  }
}
