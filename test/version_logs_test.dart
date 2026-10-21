import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/version_logs.dart';
import 'package:free_your_launcher/main.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late LauncherController controller;
  late GameInstance first, second;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-version-logs-');
    controller = LauncherController(
      supportDirectory: directory.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    first = GameInstance(
      id: 'first',
      name: 'First',
      version: '1.21.1',
      root: directory.path,
      isolated: true,
      javaMajor: 21,
    );
    second = GameInstance(
      id: 'second',
      name: 'Second',
      version: first.version,
      root: first.root,
      isolated: true,
      javaMajor: 21,
    );
    controller.instances.addAll([first, second]);
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  Future<File> logFile(GameInstance instance, int stamp, String text) async {
    final file = File(
      p.join(instance.launcherDirectory, 'logs', '$stamp-1.log'),
    );
    await file.parent.create(recursive: true);
    return file.writeAsString(text);
  }

  test(
    'retention defaults to one and protects active clients and unrelated files',
    () async {
      expect(controller.settings.retainedGameLogs, 1);
      final old = await logFile(first, 1700000000000, 'old');
      final latest = await logFile(first, 1700000000001, 'latest');
      final unrelated = File(p.join(old.parent.path, 'notes.log'));
      await unrelated.writeAsString('keep');
      await pruneVersionLogs(first, 1, {old.path});
      expect(await old.exists(), isTrue);
      await pruneVersionLogs(first, 1, {});
      expect(await old.exists(), isFalse);
      expect(await latest.exists(), isTrue);
      expect(await unrelated.readAsString(), 'keep');
      final saved = LauncherSettings.fromJson(
        controller.settings.toJson()..['retainedGameLogs'] = 2,
        directory.path,
      );
      expect(saved.retainedGameLogs, 2);
      saved.retainedGameLogs = 0;
      expect(saved.validate(), isNotNull);
    },
  );

  test(
    'each version reloads its own latest log and exit code after restart',
    () async {
      final a = await logFile(first, 1700000000001, 'first version\n');
      final b = await logFile(second, 1700000000002, 'second version\n');
      await saveLatestLog(
        first,
        VersionLog(a.path, DateTime(2024), exitCode: 0),
      );
      await saveLatestLog(
        second,
        VersionLog(b.path, DateTime(2024), exitCode: 1),
      );
      expect((await controller.loadVersionLog(first.id))!.lines, [
        'first version',
      ]);
      expect((await controller.loadVersionLog(second.id))!.lines, [
        'second version',
      ]);
      expect(controller.versionLogs[first.id]!.exitCode, 0);
      expect(controller.versionLogs[second.id]!.exitCode, 1);
    },
  );

  test(
    'metadata cannot direct the log reader outside the version log folder',
    () async {
      final metadata = File(
        p.join(first.launcherDirectory, 'logs', 'latest.json'),
      );
      await metadata.parent.create(recursive: true);
      await metadata.writeAsString(
        '{"file":"../../private.log","startedAt":"2024-01-01"}',
      );
      expect(await readLatestLog(first), isNull);
    },
  );

  testWidgets(
    'logs are opened per version beside Java settings and absent from downloads',
    (tester) async {
      controller.versionLogs[first.id] = VersionLog('first.log', DateTime(2024))
        ..lines.add('first output');
      controller.versionLogs[second.id] = VersionLog(
        'second.log',
        DateTime(2024),
      )..lines.add('second output');
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('navigation-2')));
      await tester.pumpAndSettle();
      expect(find.text('运行日志'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('navigation-1')));
      await tester.pumpAndSettle();
      final button = find.byKey(ValueKey('instance-log-${first.id}'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('First · 运行日志'), findsOneWidget);
      expect(find.text('first output'), findsOneWidget);
      expect(find.text('second output'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
