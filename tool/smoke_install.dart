// dart run tool/smoke_install.dart [version] [--launch]
// Uses only build/smoke-data, separate from the user's real launcher profiles.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final versionId =
      args.where((arg) => !arg.startsWith('--')).firstOrNull ?? '1.21.1';
  final root = p.join(Directory.current.path, 'build', 'smoke-data');
  final settings = LauncherSettings(
    gameRoot: root,
    username: 'Launcher_Test',
    parallelDownloads: 12,
  );
  final host = await HostPlatform.detect();
  final network = OfficialNetwork(settings);
  try {
    final manifest = await network.json(versionManifestUrl);
    final version = (manifest['versions'] as List<dynamic>)
        .map((v) => MinecraftVersion.fromJson(v as Json))
        .firstWhere((v) => v.id == versionId);
    final task = InstallTask(version, 'Smoke test $versionId', settings);
    var last = DateTime.fromMillisecondsSinceEpoch(0);
    final instance = await MinecraftInstaller(host, network).install(
      task,
      CancellationToken(),
      () {
        final now = DateTime.now();
        if (now.difference(last).inSeconds >= 2) {
          stdout.writeln(
            '${task.stage} ${task.completedFiles}/${task.totalFiles} ${(task.downloadedBytes / 1048576).toStringAsFixed(1)} MB',
          );
          last = now;
        }
      },
    );
    await writeJson(
      File(p.join(root, 'smoke-instance.json')),
      instance.toJson(),
    );
    final command = await MinecraftRunner(host).prepare(instance, settings);
    stdout.writeln(
      'INSTALL_OK ${instance.version}; Java: ${command.executable}; gameDir: ${command.workingDirectory}',
    );
    if (args.contains('--launch')) {
      final process = await Process.start(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
      );
      final log = File(p.join(root, 'smoke-game.log')).openWrite();
      var initialized = false;
      void line(String text) {
        log.writeln(text);
        if (text.contains('OpenAL initialized') ||
            text.contains('Created:') ||
            text.contains('Sound engine started')) {
          initialized = true;
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
      final code = await process.exitCode.timeout(
        const Duration(seconds: 80),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      await Future.wait([output, errors]);
      await log.close();
      stdout.writeln('GAME_INITIALIZED=$initialized EXIT=$code');
      if (!initialized) exitCode = 1;
    }
  } catch (e, stack) {
    stderr.writeln('$e\n$stack');
    exitCode = 1;
  } finally {
    network.close();
  }
}
