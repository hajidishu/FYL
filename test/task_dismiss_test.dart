import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets(
    'finished tasks can be dismissed without deleting games or active tasks',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('fyl-task-dismiss-'),
      );
      final controller = LauncherController(
        supportDirectory: root!.path,
        platform: const HostPlatform('windows', 'x86_64'),
      );
      final game = GameInstance(
        id: 'game',
        name: 'Installed Game',
        version: '1.21.1',
        root: root.path,
        isolated: true,
        javaMajor: 21,
      );
      controller.instances.add(game);
      final installedFile = await tester.runAsync(() async {
        final file = File(p.join(game.gameDirectory, 'options.txt'));
        await file.parent.create(recursive: true);
        return file.writeAsString('installed data');
      });
      InstallTask task(String name) => InstallTask(
        MinecraftVersion.fromJson({
          'id': '1.21.1',
          'type': 'release',
          'url': 'https://example.invalid/version',
          'releaseTime': '2024-01-01T00:00:00Z',
        }),
        name,
        controller.settings,
      );
      final finished = task(game.name)
        ..status = TaskStatus.completed
        ..stage = '安装完成';
      final active = task('Active')
        ..completedFiles = 1
        ..totalFiles = 2;
      final mod =
          ContentTask('Finished Mod', ContentKind.mod, ContentSource.modrinth)
            ..state = ContentTaskState.completed
            ..stage = '安装完成';
      controller.tasks.addAll([finished, active]);
      controller.content.tasks.add(mod);
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.tap(find.byKey(const ValueKey('navigation-2')));
      await tester.pumpAndSettle();
      final closeContent = find.byKey(
        ValueKey('dismiss-content-task-${mod.id}'),
      );
      await tester.ensureVisible(closeContent);
      await tester.tap(closeContent);
      await tester.pumpAndSettle();
      expect(controller.content.tasks, isEmpty);
      final closeGame = find.byKey(
        ValueKey('dismiss-install-task-${identityHashCode(finished)}'),
      );
      await tester.ensureVisible(closeGame);
      await tester.tap(closeGame);
      await tester.pumpAndSettle();
      expect(controller.tasks, [active]);
      expect(controller.dismissInstallTask(active), isFalse);
      final waiting = ContentTask(
        'Waiting',
        ContentKind.mod,
        ContentSource.curseforge,
      )..state = ContentTaskState.waiting;
      controller.content.tasks.add(waiting);
      expect(controller.dismissContentTask(waiting), isFalse);
      expect(controller.instances.single.id, game.id);
      expect(
        await tester.runAsync(installedFile!.readAsString),
        'installed data',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
