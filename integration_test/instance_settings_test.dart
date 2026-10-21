import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/pack_import.dart';
import 'package:free_your_launcher/main.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native instance settings, Mod toggle and mrpack export',
    (tester) async {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1180, 780));
      final temporary = await Directory.systemTemp.createTemp(
        'fyl-native-instance-',
      );
      final controller = LauncherController(
        supportDirectory: temporary.path,
        platform: await HostPlatform.detect(),
      );
      await controller.initialize();
      controller.settings.theme = 'light';
      final instance = GameInstance(
        id: 'native-example',
        name: 'Fabric 1.21.1',
        version: '1.21.1',
        root: temporary.path,
        isolated: true,
        javaMajor: 21,
        components: 'Fabric 0.19.3',
        favorite: true,
        description: 'Minecraft 1.21.1，Fabric 0.19.3。',
        installation: {
          'loader': {'type': 'fabric', 'version': '0.19.3'},
        },
      );
      controller.instances.add(instance);
      final modDirectory = Directory(p.join(instance.gameDirectory, 'mods'));
      await modDirectory.create(recursive: true);
      final smokeRecord = File(
        p.join(
          Directory.current.parent.path,
          'content-smoke',
          'modpack-instance.json',
        ),
      );
      if (await smokeRecord.exists()) {
        final smoke = GameInstance.fromJson(
          jsonDecode(await smokeRecord.readAsString()) as Json,
        );
        final files = await Directory(p.join(smoke.gameDirectory, 'mods'))
            .list(followLinks: false)
            .where((f) => f is File && f.path.endsWith('.jar'))
            .take(12)
            .toList();
        for (final file in files) {
          await (file as File).copy(
            p.join(modDirectory.path, p.basename(file.path)),
          );
        }
      }
      if (await modDirectory.list().isEmpty) {
        final bytes = utf8.encode(
          '{"id":"example","name":"Example Mod","version":"1.0","description":"An example mod"}',
        );
        final archive = Archive()
          ..addFile(ArchiveFile('fabric.mod.json', bytes.length, bytes));
        await File(
          p.join(modDirectory.path, 'example.jar'),
        ).writeAsBytes(ZipEncoder().encode(archive));
      }
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
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          p.join(Directory.current.path, 'build', 'screenshots', '$name.png'),
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      Future<void> waitFor(Finder finder) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(finder, findsWidgets);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byKey(const ValueKey('navigation-1')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('instance-settings-${instance.id}')),
      );
      await tester.pumpAndSettle();
      await screenshot('instance-overview');
      await tester.ensureVisible(find.text('版本隔离'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('版本隔离'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启：使用版本文件夹'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭：使用游戏根目录').last);
      await tester.pumpAndSettle();
      await screenshot('version-isolation');
      await tester.tap(find.text('切换目录'));
      await tester.pumpAndSettle();
      expect(controller.instances.single.gameDirectory, instance.root);
      await tester.tap(find.text('版本隔离'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭：使用游戏根目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开启：使用版本文件夹').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('切换目录'));
      await tester.pumpAndSettle();
      expect(
        controller.instances.single.gameDirectory,
        instance.versionDirectory,
      );
      await tester.tap(find.byKey(const ValueKey('instance-tab-1')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('单独设置内存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单独设置内存'));
      await tester.pumpAndSettle();
      final memory = find.descendant(
        of: find.byKey(const ValueKey('instance-field-maxMemory')),
        matching: find.byType(EditableText),
      );
      await tester.ensureVisible(memory);
      await tester.pumpAndSettle();
      await tester.enterText(memory, '4096');
      await tester.tap(find.byKey(const ValueKey('save-instance-settings')));
      await waitFor(find.text('版本设置已保存'));
      expect(controller.instances.single.launchSettings.maxMemory, 4096);
      await tester.ensureVisible(find.text('Java'));
      await tester.pumpAndSettle();
      await screenshot('instance-launch-settings');
      await tester.ensureVisible(find.text('高级启动选项'));
      await tester.pumpAndSettle();
      await screenshot('instance-advanced-settings');
      await tester.tap(find.byKey(const ValueKey('instance-tab-2')));
      await tester.pump();
      await waitFor(find.byType(Switch));
      await screenshot('instance-mod-manager');
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (find.byType(LinearProgressIndicator).evaluate().isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(
        await modDirectory
            .list()
            .where((f) => f.path.endsWith('.jar.disabled'))
            .length,
        1,
      );
      controller.settings.theme = 'dark';
      controller.notifyListeners();
      await tester.pumpAndSettle();
      await screenshot('instance-mod-manager-dark');
      await tester.tap(find.byKey(const ValueKey('instance-tab-3')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('选择位置并导出'));
      await tester.pumpAndSettle();
      await screenshot('instance-export');
      if (Platform.isWindows) {
        final output = p.join(
          Directory.current.path,
          'build',
          'native-instance-export',
          'FYL Native.mrpack',
        );
        if (await File(output).exists()) await File(output).delete();
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
        final helperOutput = helper.stdout
            .transform(const SystemEncoding().decoder)
            .join();
        final helperErrors = helper.stderr
            .transform(const SystemEncoding().decoder)
            .join();
        await tester.tap(find.text('选择位置并导出'));
        await tester.pump();
        final exportDeadline = DateTime.now().add(const Duration(seconds: 40));
        while (!await File(output).exists() &&
            DateTime.now().isBefore(exportDeadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(await helper.exitCode, 0, reason: await helperErrors);
        expect(await helperOutput, contains('"nativeDialog":true'));
        expect(await File(output).exists(), isTrue);
        await tester.pumpAndSettle();
        final plan = await inspectModpack(output);
        expect(plan.loaderVersion, '0.19.3');
        expect(plan.overrides, isNotEmpty);
        await screenshot('instance-export-completed');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await temporary.delete(recursive: true);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
