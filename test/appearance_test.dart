import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/settings_page.dart';
import 'package:free_your_launcher/ui/theme.dart';

void main() {
  testWidgets(
    'custom accent persists and resets without resetting other settings',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('fyl-appearance-'),
      );
      final controller = LauncherController(
        supportDirectory: root!.path,
        platform: const HostPlatform('windows', 'x86_64'),
      );
      controller.settings.theme = 'light';
      controller.settings.maxMemory = 4096;
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.tap(find.byKey(const ValueKey('navigation-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('choose-accent')));
      await tester.pumpAndSettle();
      final edit = find.descendant(
        of: find.byKey(const ValueKey('accent-hex')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(edit, '#7C3AED');
      await tester.tap(find.text('使用此色调'));
      await tester.pumpAndSettle();
      final state = tester.state<SettingsPageState>(find.byType(SettingsPage));
      await tester.runAsync(state.save);
      await tester.pumpAndSettle();
      expect(controller.settings.accentColor, 0x7c3aed);
      expect(controller.settings.copy().accentColor, 0x7c3aed);
      final context = tester.element(find.byType(SettingsPage));
      expect(
        LauncherColors.of(context).accent,
        LauncherColors(false, accentColor: 0x7c3aed).accent,
      );
      await tester.ensureVisible(find.byKey(const ValueKey('reset-accent')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reset-accent')));
      await tester.pumpAndSettle();
      await tester.runAsync(state.save);
      await tester.pumpAndSettle();
      expect(controller.settings.accentColor, isNull);
      expect(controller.settings.maxMemory, 4096);
      expect(controller.settings.theme, 'light');
      expect(
        LauncherColors.of(context).accent,
        const LauncherColors(false).accent,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
