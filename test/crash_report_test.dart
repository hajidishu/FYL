import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/crash_report.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/version_logs.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/game_failure_dialog.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:path/path.dart' as p;

class ObservedFailure extends GameFailure {
  final reportDone = Completer<void>();
  final logDone = Completer<void>();
  ObservedFailure(GameFailure source)
    : super(
        instanceId: source.instanceId,
        instanceName: source.instanceName,
        logPath: source.logPath,
        exitCode: source.exitCode,
        files: source.files,
      );
  @override
  Future<void> exportReport(String destination) async {
    try {
      await super.exportReport(destination);
      reportDone.complete();
    } catch (error, stack) {
      reportDone.completeError(error, stack);
      rethrow;
    }
  }

  @override
  Future<void> exportLog(String destination) async {
    try {
      await super.exportLog(destination);
      logDone.complete();
    } catch (error, stack) {
      logDone.completeError(error, stack);
      rethrow;
    }
  }
}

void main() {
  late Directory directory;
  late GameInstance instance;
  late VersionLog log;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-crash-report-');
    instance = GameInstance(
      id: 'crashed',
      name: 'Crash Test',
      version: '1.21.1',
      root: directory.path,
      isolated: true,
      javaMajor: 21,
      components: 'Fabric 0.16.10',
    );
    final file = File(
      p.join(instance.launcherDirectory, 'logs', '1700000000000-1.log'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      'Failure details\naccess_token=unit-secret-access-token\n'
      'Authorization: Bearer unit-bearer-value\n'
      'Authorization: Basic dW5pdDpwYXNzd29yZA==\n'
      '-----BEGIN RSA PRIVATE KEY-----\nunit-private-key-content\n'
      '-----END RSA PRIVATE KEY-----\nAfter credentials\n',
    );
    log = VersionLog(
      file.path,
      DateTime.now().subtract(const Duration(minutes: 1)),
      endedAt: DateTime.now().add(const Duration(minutes: 1)),
      exitCode: 42,
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<File> gameFile(String name, String text) async {
    final file = File(p.join(instance.gameDirectory, name));
    await file.parent.create(recursive: true);
    return file.writeAsString(text);
  }

  Future<GameFailure> capture({bool shared = true}) => captureGameFailure(
    instance: instance,
    log: log,
    platform: const HostPlatform('windows', 'x86_64'),
    java: 'java',
    minMemory: 512,
    maxMemory: 2048,
    exitCode: 42,
    includeGameLogs: shared,
    secrets: ['unit-secret-access-token'],
  );

  test('reports include relevant diagnostics and filter credentials', () async {
    await gameFile(
      'logs/latest.log',
      'Minecraft failure\npassword=unit-password-value',
    );
    await gameFile('crash-reports/current.txt', 'Crash details');
    await gameFile('launcher.json', 'private-settings-must-not-be-exported');
    await gameFile('mods/example.jar', 'not a real jar');
    final report = await capture();
    final destination = p.join(directory.path, 'report.zip');
    await report.exportReport(destination);
    final archive = ZipDecoder().decodeBytes(
      await File(destination).readAsBytes(),
    );
    final files = {
      for (final file in archive.files) file.name: utf8.decode(file.content),
    };
    expect(
      files.keys,
      containsAll([
        'report.txt',
        'launcher.log',
        'minecraft-latest.log',
        'minecraft-crash-report.txt',
      ]),
    );
    final text = files.values.join('\n');
    expect(text, contains('退出码: 42'));
    expect(text, contains('example.jar'));
    expect(text, isNot(contains('unit-secret-access-token')));
    expect(text, isNot(contains('unit-bearer-value')));
    expect(text, isNot(contains('unit-password-value')));
    expect(text, isNot(contains('dW5pdDpwYXNzd29yZA==')));
    expect(text, isNot(contains('unit-private-key-content')));
    expect(text, contains('After credentials'));
    expect(text, isNot(contains('private-settings-must-not-be-exported')));
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null) {
      expect(sanitizeDiagnosticText('$home/example'), isNot(contains(home)));
    }
  });

  test(
    'old and shared Minecraft logs are excluded from the wrong client report',
    () async {
      final latest = await gameFile(
        'logs/latest.log',
        'stale Minecraft output',
      );
      await latest.setLastModified(
        log.startedAt.subtract(const Duration(days: 1)),
      );
      expect((await capture()).files, isNot(contains('minecraft-latest.log')));
      await latest.setLastModified(DateTime.now());
      expect(
        (await capture(shared: false)).files,
        isNot(contains('minecraft-latest.log')),
      );
    },
  );

  test(
    'standalone log export is sanitized and cannot overwrite its source',
    () async {
      final destination = p.join(directory.path, 'export.log');
      await exportSanitizedLog(
        log.path,
        destination,
        secrets: ['unit-secret-access-token'],
      );
      final text = await File(destination).readAsString();
      expect(text, contains('Failure details'));
      expect(text, isNot(contains('unit-secret-access-token')));
      expect(text, isNot(contains('unit-bearer-value')));
      expect(text, isNot(contains('dW5pdDpwYXNzd29yZA==')));
      expect(text, isNot(contains('unit-private-key-content')));
      expect(text, contains('After credentials'));
      await expectLater(
        exportSanitizedLog(log.path, log.path),
        throwsFormatException,
      );
      expect(
        await File(log.path).readAsString(),
        contains('unit-secret-access-token'),
      );
    },
  );

  testWidgets('abnormal exits are shown as separate queued dialogs', (
    tester,
  ) async {
    final controller = LauncherController(
      supportDirectory: directory.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    addTearDown(controller.dispose);
    for (final name in ['First', 'Second']) {
      controller.gameFailures.add(
        GameFailure(
          instanceId: name,
          instanceName: name,
          logPath: log.path,
          exitCode: 1,
          files: const {'report.txt': 'test'},
        ),
      );
    }
    await tester.pumpWidget(
      LauncherApp(controller: controller, nativeWindow: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('First非正常退出'), findsOneWidget);
    expect(
      find.text('下方可导出错误报告和游戏日志，如果你需要向他人求助请发送错误报告而不是此页面的截图'),
      findsOneWidget,
    );
    expect(find.text('导出错误报告'), findsOneWidget);
    expect(find.text('导出游戏日志'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('Second非正常退出'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(controller.gameFailures, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dialog export buttons save both reports and game logs', (
    tester,
  ) async {
    final failure = (await tester.runAsync(
      () async => ObservedFailure(await capture()),
    ))!;
    final reportPath = p.join(directory.path, 'button-report.zip');
    final logPath = p.join(directory.path, 'button-log.log');
    await tester.pumpWidget(
      MaterialApp(
        theme: const LauncherColors(false).material,
        home: FTheme(
          data: const LauncherColors(false).forui,
          child: Scaffold(
            body: GameFailureDialog(
              failure: failure,
              savePicker: (_, extension) async =>
                  extension == 'zip' ? reportPath : logPath,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      tester
          .widget<AppButton>(find.byKey(const ValueKey('export-error-report')))
          .onPressed!();
      await failure.reportDone.future.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      tester
          .widget<AppButton>(find.byKey(const ValueKey('export-game-log')))
          .onPressed!();
      await failure.logDone.future.timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
