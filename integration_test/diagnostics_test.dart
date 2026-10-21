import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/crash_report.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/version_logs.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('version logs and native diagnostic report exports', (
    tester,
  ) async {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1180, 780));
    final temporary = await Directory.systemTemp.createTemp(
      'fyl-native-diagnostics-',
    );
    final controller = LauncherController(
      supportDirectory: temporary.path,
      platform: await HostPlatform.detect(),
    );
    await controller.initialize();
    final instance = GameInstance(
      id: 'diagnostic',
      name: 'Diagnostics Demo',
      version: '1.21.1',
      root: temporary.path,
      isolated: true,
      javaMajor: 21,
    );
    controller.instances.add(instance);
    final path = p.join(
      instance.launcherDirectory,
      'logs',
      '${DateTime.now().millisecondsSinceEpoch}-1.log',
    );
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(
      'Example game error\naccess_token=native-test-credential\n',
    );
    controller.versionLogs[instance.id] = VersionLog(
      path,
      DateTime.now(),
      exitCode: 42,
    )..lines.add('Example game error');
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: LauncherApp(controller: controller, nativeWindow: false),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> screenshot(String name) async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File(
        p.join(Directory.current.path, 'build', 'screenshots', '$name.png'),
      );
      await output.parent.create(recursive: true);
      await output.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    await tester.tap(find.byKey(const ValueKey('navigation-2')));
    await tester.pumpAndSettle();
    expect(find.text('运行日志'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('navigation-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('instance-log-${instance.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics Demo · 运行日志'), findsOneWidget);
    expect(find.text('Example game error'), findsOneWidget);
    await screenshot('version-runtime-logs');

    controller.gameFailures.add(
      GameFailure(
        instanceId: instance.id,
        instanceName: instance.name,
        logPath: path,
        exitCode: 42,
        files: const {
          'report.txt': 'FYL diagnostic report\nExit code: 42',
          'launcher.log':
              'Example game error\naccess_token=native-test-credential',
        },
      ),
    );
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics Demo非正常退出'), findsOneWidget);
    await screenshot('game-abnormal-exit');

    Future<String> save(String key, String extension) async {
      final output = p.join(
        Directory.current.path,
        'build',
        'native-diagnostics',
        '${DateTime.now().microsecondsSinceEpoch}.$extension',
      );
      await Directory(p.dirname(output)).create(recursive: true);
      final helper = await Process.start('powershell.exe', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(
          Directory.current.path,
          'integration_test',
          'native_save_dialog.ps1',
        ),
        '-OwnerPid',
        '$pid',
        '-ExpectedExecutable',
        p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Debug',
          'free_your_launcher.exe',
        ),
        '-OutputPath',
        output,
      ]);
      final out = helper.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final errors = helper.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pump();
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        final ready =
            tester.widget<AppButton>(find.byKey(ValueKey(key))).onPressed !=
            null;
        if (ready && await File(output).exists()) break;
      }
      expect(
        await helper.exitCode.timeout(const Duration(seconds: 15)),
        0,
        reason: await errors,
      );
      expect(await out, contains('"nativeDialog":true'));
      expect(await File(output).exists(), isTrue);
      await tester.pumpAndSettle();
      return output;
    }

    if (Platform.isWindows) {
      final zip = await save('export-error-report', 'zip');
      final archive = ZipDecoder().decodeBytes(await File(zip).readAsBytes());
      expect(archive.findFile('report.txt'), isNotNull);
      expect(
        utf8.decode(archive.findFile('launcher.log')!.content),
        isNot(contains('native-test-credential')),
      );
      final exported = await save('export-game-log', 'log');
      expect(
        await File(exported).readAsString(),
        contains('Example game error'),
      );
      expect(
        await File(exported).readAsString(),
        isNot(contains('native-test-credential')),
      );
    }
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(controller.gameFailures, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await temporary.delete(recursive: true);
  });
}
