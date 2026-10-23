import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/settings_page.dart';
import 'package:free_your_launcher/ui/pages.dart';
import 'package:free_your_launcher/ui/theme.dart';

void main() {
  late LauncherController controller;
  setUp(() {
    controller = LauncherController(
      supportDirectory: Directory.systemTemp.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
  });
  tearDown(() => controller.dispose());
  testWidgets(
    'home cards fit wrapped validation text and fractional display scaling',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final theme in ['light', 'dark']) {
        controller.settings.theme = theme;
        controller.settings.username = 'ab';
        for (final width in [1036.0, 1100.0, 1180.0, 1280.0]) {
          tester.view.devicePixelRatio = 1.25;
          tester.view.physicalSize = Size(width * 1.25, 780 * 1.25);
          await tester.pumpWidget(
            LauncherApp(
              key: UniqueKey(),
              controller: controller,
              nativeWindow: false,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$theme theme, width $width, invalid username',
          );
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final size in [const Size(1180, 780), const Size(800, 600)]) {
    testWidgets('home and grouped settings fit ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择游戏版本和账号。'), findsOneWidget);
      expect(find.text('尚未添加账号'), findsOneWidget);
      expect(find.text('切换账号'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('navigation-3')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsPage), findsOneWidget);
      await tester.tap(find.text('游戏与隔离'));
      await tester.pumpAndSettle();
      expect(find.text('新版本默认启用版本隔离'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('下载与版本'));
      await tester.pumpAndSettle();
      expect(find.text('默认展开预览版'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets(
    'latest Minecraft release is separate and filtering stays consistent',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final id in ['1.21.1', '1.20.1']) {
        controller.versions.add(
          MinecraftVersion.fromJson({
            'id': id,
            'type': 'release',
            'url': 'https://piston-meta.mojang.com/$id.json',
            'releaseTime': '2024-08-08T00:00:00Z',
          }),
        );
      }
      controller.latestRelease = '1.21.1';
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.tap(find.byKey(const ValueKey('navigation-2')));
      await tester.pumpAndSettle();
      expect(find.text('最新版本'), findsOneWidget);
      expect(find.text('正式版 (2)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('install-version-1.21.1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('version-group-release')));
      await tester.pumpAndSettle();
      expect(find.text('1.20.1'), findsOneWidget);
      await tester.enterText(find.byType(EditableText).first, '1.20.1');
      await tester.pumpAndSettle();
      expect(find.text('正式版 (1)'), findsOneWidget);
      expect(find.text('1.21.1'), findsNothing);
      expect(find.text('最新正式版'), findsNothing);
      await tester.enterText(find.byType(EditableText).first, '1.21.1');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('install-version-1.21.1')),
        findsOneWidget,
      );
      expect(find.text('最新正式版'), findsOneWidget);
      expect(find.textContaining('其他版本'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('empty instance library links to downloads', (tester) async {
    tester.view.physicalSize = const Size(1180, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      LauncherApp(controller: controller, nativeWindow: false),
    );
    await tester.tap(find.byKey(const ValueKey('navigation-1')));
    await tester.pumpAndSettle();
    expect(find.text('尚未安装游戏'), findsOneWidget);
    await tester.tap(find.text('去下载游戏'));
    await tester.pumpAndSettle();
    expect(find.text('版本列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final size in [const Size(800, 600), const Size(1180, 780)]) {
    testWidgets(
      'empty download tasks are centered in the content area at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          LauncherApp(controller: controller, nativeWindow: false),
        );
        await tester.tap(find.byKey(const ValueKey('navigation-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载任务 (0)'));
        await tester.pumpAndSettle();
        final page = tester.getRect(find.byType(DownloadsPage));
        final body = tester.getRect(
          find.byKey(const ValueKey('downloads-content')),
        );
        final placeholder = tester.getRect(find.byType(EmptyState));
        expect(placeholder.center.dx, closeTo(page.center.dx, 1));
        expect(placeholder.center.dy, closeTo(body.center.dy, 1));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('浏览版本'));
        await tester.pumpAndSettle();
        expect(find.text('暂无下载任务'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
