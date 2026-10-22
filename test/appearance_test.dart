import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/settings_page.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:free_your_launcher/ui/launcher_background.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets(
    'background is retained locally, excludes the sidebar and preserves accent',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('fyl-background-'),
      );
      final source = await tester.runAsync(
        () => File(
          'assets/brand/icon.png',
        ).copy(p.join(root!.path, 'source.png')),
      );
      final managed = await tester.runAsync(
        () => importLauncherBackground(source!.path, root!.path),
      );
      await tester.runAsync(source!.delete);
      final controller = LauncherController(
        supportDirectory: root!.path,
        platform: const HostPlatform('windows', 'x86_64'),
      );
      controller.settings.accentColor = 0x2563eb;
      controller.settings.backgroundPath = managed;
      await tester.runAsync(
        () => controller.saveSettings(controller.settings.copy()),
      );
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      final image = find.byKey(const ValueKey('launcher-background-image'));
      expect(image, findsOneWidget);
      expect(tester.getRect(image).left, greaterThanOrEqualTo(76));
      expect(
        LauncherColors.of(tester.element(image)).accent,
        LauncherColors(true, accentColor: 0x2563eb).accent,
      );
      final restored = LauncherController(
        supportDirectory: root.path,
        platform: controller.platform,
      );
      await tester.runAsync(restored.initialize);
      expect(restored.settings.backgroundPath, managed);
      expect(restored.settings.accentColor, 0x2563eb);
      controller.settings.backgroundPath = p.join(root.path, 'missing.png');
      controller.notifyListeners();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      restored.dispose();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
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
