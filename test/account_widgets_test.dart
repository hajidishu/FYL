import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/account_widgets.dart';
import 'account_test_support.dart';

void main() {
  late Directory directory;
  late LauncherController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-account-ui-');
    controller = LauncherController(
      supportDirectory: directory.path,
      platform: const HostPlatform('windows', 'x86_64'),
      tokenStore: MemoryTokenStore(),
    );
    await controller.initialize();
    await controller.addOfflineAccount('Local_Player');
    controller.accounts.add(
      const LauncherAccount(
        id: 'microsoft:test',
        kind: AccountKind.microsoft,
        username: 'Online_Player',
        uuid: '12345678901234567890123456789012',
      ),
    );
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });
  testWidgets(
    'homepage avatar reveals switching on hover and combines both account kinds',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('Local_Player'), findsOneWidget);
      expect(find.text('切换账号'), findsNothing);
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: Offset.zero);
      await pointer.moveTo(tester.getCenter(find.byType(SkinAvatar).first));
      await tester.pumpAndSettle();
      expect(find.text('切换账号'), findsWidgets);
      await tester.tap(find.text('添加账号'));
      await tester.pumpAndSettle();
      Finder inAccounts(String text) => find.descendant(
        of: find.byType(AccountManagerDialog),
        matching: find.text(text),
      );
      expect(inAccounts('Online_Player'), findsOneWidget);
      expect(inAccounts('Local_Player'), findsOneWidget);
      expect(inAccounts('正版账号'), findsOneWidget);
      expect(inAccounts('离线账号'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(inAccounts('Online_Player'));
        await controller.flush();
      });
      await tester.pumpAndSettle();
      expect(controller.activeAccount!.username, 'Online_Player');
      expect(find.byType(AccountManagerDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await pointer.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('offline account creation stays on the homepage', (tester) async {
    tester.view.physicalSize = const Size(1180, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      LauncherApp(controller: controller, nativeWindow: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加离线账号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'New_Player');
    await tester.runAsync(() async {
      await tester.tap(find.text('创建并使用'));
      await controller.flush();
    });
    await tester.pumpAndSettle();
    expect(controller.activeAccount!.username, 'New_Player');
    expect(controller.accounts.length, 3);
    expect(find.text('New_Player'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
