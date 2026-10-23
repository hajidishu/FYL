import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/theme.dart';

void main() {
  late Directory temporary;
  late LauncherController controller;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-memory-ui-');
    controller = LauncherController(
      supportDirectory: temporary.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    controller.instances.add(
      GameInstance(
        id: 'game',
        name: 'Game',
        version: '1.21.1',
        root: temporary.path,
        isolated: true,
        javaMajor: 21,
      ),
    );
  });
  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });

  Finder input(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(EditableText),
  );
  Future<void> choose<T>(WidgetTester tester, String key, T value) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    tester.widget<SelectBox<T>>(finder).onChanged!(value);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester, Finder button) async {
    await tester.ensureVisible(button);
    await tester.runAsync(() async {
      await tester.tap(button);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await controller.flush();
    });
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(800, 600), const Size(1158, 762)]) {
    testWidgets(
      'memory modes preserve manual values and instance inheritance at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          LauncherApp(controller: controller, nativeWindow: false),
        );
        await tester.tap(find.byKey(const ValueKey('navigation-3')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('默认 Java 与内存'));
        await tester.pumpAndSettle();
        await choose(tester, 'default-memory-mode', false);
        await tester.ensureVisible(input('settings-field-maxMemory'));
        await tester.enterText(input('settings-field-maxMemory'), '6144');
        await choose(tester, 'default-memory-mode', true);
        await tester.ensureVisible(input('settings-field-autoMemoryLimit'));
        await tester.enterText(input('settings-field-autoMemoryLimit'), '8192');
        await choose(tester, 'default-memory-mode', false);
        expect(
          tester
              .widget<EditableText>(input('settings-field-maxMemory'))
              .controller
              .text,
          '6144',
        );
        await choose(tester, 'default-memory-mode', true);
        await save(tester, find.text('保存修改'));
        expect(controller.settings.automaticMemory, isTrue);
        expect(controller.settings.autoMemoryLimit, 8192);
        expect(controller.settings.minMemory, 0);
        expect(controller.settings.maxMemory, 6144);
        await tester.tap(find.byKey(const ValueKey('navigation-1')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('instance-settings-game')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('instance-settings-game')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('instance-tab-1')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SelectBox<int>>(
                find.byKey(const ValueKey('instance-memory-mode')),
              )
              .value,
          -1,
        );
        await choose(tester, 'instance-memory-mode', 1);
        await tester.ensureVisible(input('instance-field-maxMemory'));
        await tester.enterText(input('instance-field-maxMemory'), '4096');
        await choose(tester, 'instance-memory-mode', 0);
        await tester.ensureVisible(input('instance-field-autoMemoryLimit'));
        await tester.enterText(input('instance-field-autoMemoryLimit'), '3200');
        await save(
          tester,
          find.byKey(const ValueKey('save-instance-settings')),
        );
        final own = controller.instances.single.launchSettings;
        expect(own.automaticMemory, isTrue);
        expect(own.autoMemoryLimit, 3200);
        expect(own.maxMemory, 4096);
        expect(controller.settings.autoMemoryLimit, 8192);
        await choose(tester, 'instance-memory-mode', -1);
        await save(
          tester,
          find.byKey(const ValueKey('save-instance-settings')),
        );
        expect(
          controller.instances.single.launchSettings.automaticMemory,
          isNull,
        );
        expect(controller.instances.single.launchSettings.minMemory, isNull);
        expect(controller.instances.single.launchSettings.maxMemory, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
