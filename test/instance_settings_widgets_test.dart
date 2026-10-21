import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/instance_details.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late LauncherController controller;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-instance-widget-');
    controller = LauncherController(
      supportDirectory: temporary.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    for (final id in ['first', 'second']) {
      controller.instances.add(
        GameInstance(
          id: id,
          name: id,
          version: '1.21.1',
          root: temporary.path,
          isolated: true,
          javaMajor: 21,
          components: 'Fabric 0.16.10',
        ),
      );
    }
    final bytes = utf8.encode(
      jsonEncode({
        'id': 'demo',
        'name': 'Example Mod',
        'version': '1.0',
        'description': 'A test mod',
      }),
    );
    final archive = Archive()
      ..addFile(ArchiveFile('fabric.mod.json', bytes.length, bytes));
    final jar = File(
      p.join(controller.instances.first.gameDirectory, 'mods', 'demo.jar'),
    );
    await jar.parent.create(recursive: true);
    await jar.writeAsBytes(ZipEncoder().encode(archive));
  });
  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });
  Finder edit(String key) => find.descendant(
    of: find.byKey(ValueKey('instance-field-$key')),
    matching: find.byType(EditableText),
  );
  for (final size in [const Size(800, 600), const Size(1180, 780)]) {
    testWidgets(
      'instance overview/settings/mods/export fit $size and preserve per-instance choices',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          LauncherApp(controller: controller, nativeWindow: false),
        );
        await tester.tap(find.byKey(const ValueKey('navigation-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('instance-settings-first')));
        await tester.pumpAndSettle();
        expect(find.byType(InstanceDetailsPage), findsOneWidget);
        await tester.enterText(edit('name'), 'My Adventure');
        await tester.enterText(edit('description'), 'A custom instance');
        await tester.tap(find.byKey(const ValueKey('navigation-0')));
        await tester.pumpAndSettle();
        expect(find.text('有尚未保存的设置'), findsOneWidget);
        await tester.tap(find.text('返回'));
        await tester.pumpAndSettle();
        expect(find.byType(InstanceDetailsPage), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('instance-tab-1')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('单独设置内存'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('单独设置内存'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(edit('maxMemory'));
        await tester.pumpAndSettle();
        await tester.enterText(edit('maxMemory'), '4096');
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('save-instance-settings')),
          );
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while ((controller.instances.first.name != 'My Adventure' ||
                  controller.instanceOperation != null) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          await controller.flush();
        });
        await tester.pumpAndSettle();
        expect(controller.instances.first.name, 'My Adventure');
        expect(controller.instances.first.launchSettings.maxMemory, 4096);
        expect(controller.instances.last.launchSettings.maxMemory, isNull);
        expect(controller.settings.maxMemory, 2048);
        await tester.tap(find.byKey(const ValueKey('instance-tab-2')));
        await tester.pump();
        for (
          var attempt = 0;
          attempt < 30 && find.text('Example Mod · 1.0').evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.pumpAndSettle();
        expect(find.text('Example Mod · 1.0'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.byType(Switch));
          final path = p.join(
            controller.instances.first.gameDirectory,
            'mods',
            'demo.jar.disabled',
          );
          for (var i = 0; i < 30 && !await File(path).exists(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(await File(path).exists(), isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        for (
          var attempt = 0;
          attempt < 30 &&
              find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
          attempt++
        ) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });
          await tester.pump(const Duration(milliseconds: 10));
        }
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
        await tester.tap(find.byKey(const ValueKey('instance-tab-3')));
        await tester.pumpAndSettle();
        expect(find.text('导出整合包'), findsOneWidget);
        await tester.enterText(edit('packVersion'), '2.0.0');
        await tester.pumpAndSettle();
        expect(
          find.text('保存修改'),
          findsNothing,
          reason:
              'Export release version is not an instance configuration edit',
        );
        await tester.ensureVisible(find.text('选择位置并导出'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
