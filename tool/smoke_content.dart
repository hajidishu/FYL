import 'dart:async';
import 'dart:io';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/content_installer.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final root = p.join(Directory.current.path, 'build', 'smoke-data');
  final support = p.join(Directory.current.path, 'build', 'content-smoke');
  final platform = await HostPlatform.detect();
  final localJava = File(r'E:\jdk-22.0.1\bin\java.exe');
  final settings = LauncherSettings(
    gameRoot: root,
    username: 'FYL_Test',
    automaticJava: !await localJava.exists(),
    javaPath: localJava.path,
    maxMemory: 3072,
    downloadRetries: 1,
  );
  final catalog = CommunityCatalog(settings);
  GameInstance? installed;
  late ContentInstaller installer;
  var previousStage = '';
  installer = ContentInstaller(
    platform: platform,
    supportDirectory: support,
    settings: settings.copy,
    busy: () => installer.tasks.any((t) => t.state == ContentTaskState.running),
    onChanged: () {
      if (installer.tasks.isNotEmpty &&
          installer.tasks.first.stage != previousStage) {
        previousStage = installer.tasks.first.stage;
        stdout.writeln('STAGE=$previousStage');
      }
    },
    onInstalled: (instance) async {
      installed = instance;
      await writeJson(
        File(p.join(support, 'modpack-instance.json')),
        instance.toJson(),
      );
    },
  );
  try {
    final result = await catalog.search(
      kind: ContentKind.mod,
      source: ContentSource.modrinth,
      query: 'Sodium',
      minecraft: '1.21.1',
      loader: 'fabric',
    );
    if (result.projects.isEmpty) throw StateError(result.notices.join('\n'));
    final project = result.projects.firstWhere((v) => v.slug == 'sodium');
    final releases = await catalog.versions(
      project,
      CancellationToken(),
      minecraft: '1.21.1',
      loader: 'fabric',
    );
    final release = releases.versions.firstWhere(
      (v) => v.releaseType == 'release',
    );
    stdout.writeln('MOD=${project.name} / ${release.name}');
    final target = GameInstance(
      id: 'content-smoke',
      name: 'Content Smoke',
      version: '1.21.1',
      root: root,
      isolated: true,
      javaMajor: 21,
      components: 'Fabric 0.16.10',
    );
    final task = await installer.installMod(
      project,
      release,
      target,
      p.join(support, 'selected-mods', release.files.first.name),
    );
    if (task.state != ContentTaskState.completed) {
      throw StateError(task.error ?? task.stage);
    }
    stdout.writeln('MOD_INSTALLED=true');
    if (!arguments.contains('--install-pack')) return;
    final packs = await catalog.search(
      kind: ContentKind.modpack,
      source: ContentSource.modrinth,
      query: 'Fabulously Optimized',
      minecraft: '1.21.1',
      loader: 'fabric',
    );
    final pack = packs.projects.firstWhere(
      (v) => v.slug == 'fabulously-optimized',
    );
    final versions = await catalog.versions(
      pack,
      CancellationToken(),
      minecraft: '1.21.1',
      loader: 'fabric',
    );
    final selected = versions.versions.firstWhere(
      (v) => v.releaseType == 'release',
    );
    stdout.writeln('PACK=${pack.name} / ${selected.name}');
    final plan = await installer.preparePack(
      pack,
      selected,
      CancellationToken(),
    );
    stdout.writeln(
      'PLAN=${plan.minecraft} / ${plan.loaderVersion} / ${plan.files.length} files',
    );
    final packTask = await installer.installPack(
      pack,
      selected,
      plan,
      arguments
              .where((arg) => arg.startsWith('--pack-name='))
              .firstOrNull
              ?.substring(12) ??
          'Community Smoke Pack ${DateTime.now().millisecondsSinceEpoch}',
      isolated: true,
    );
    if (packTask.state != ContentTaskState.completed) {
      throw StateError(packTask.error ?? packTask.stage);
    }
    stdout.writeln('PACK_INSTALLED=true');
    final command = await MinecraftRunner(
      platform,
    ).prepare(installed!, settings);
    stdout.writeln('PACK_PREPARED=true');
    if (arguments.contains('--launch')) {
      final game = await Process.start(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
      );
      var initialized = false;
      final logs = File(p.join(support, 'game.log')).openWrite();
      void output(List<int> bytes) {
        logs.add(bytes);
        final text = String.fromCharCodes(bytes);
        if (text.contains('Sound engine started') ||
            text.contains(
              'Created: 1024x1024x4 minecraft:textures/atlas/blocks.png',
            )) {
          initialized = true;
          game.kill();
        }
      }

      final stdoutDone = game.stdout.listen(output).asFuture<void>();
      final stderrDone = game.stderr.listen(output).asFuture<void>();
      try {
        await game.exitCode.timeout(const Duration(minutes: 2));
      } on TimeoutException {
        game.kill();
        rethrow;
      } finally {
        await Future.wait([stdoutDone, stderrDone]);
        await logs.close();
      }
      stdout.writeln('GAME_INITIALIZED=$initialized');
      if (!initialized) {
        throw StateError(
          'Game did not initialize; inspect build/content-smoke/game.log',
        );
      }
    }
  } finally {
    catalog.close();
    installer.dispose();
  }
}
