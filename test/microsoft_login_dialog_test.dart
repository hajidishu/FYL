import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/microsoft_auth.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/ui/account_widgets.dart';
import 'package:free_your_launcher/ui/theme.dart';

class RejectedRegistrationAuth extends MicrosoftAuth {
  @override
  Future<DeviceLoginCode> begin(
    String clientId,
    CancellationToken token,
  ) async => DeviceLoginCode.fromJson({
    'device_code': 'device-code',
    'user_code': 'ABCD1234',
    'verification_uri': 'https://www.microsoft.com/link',
    'expires_in': 600,
  });

  @override
  Future<MicrosoftLoginResult> complete(
    String clientId,
    DeviceLoginCode code,
    CancellationToken token,
  ) async => throw const MinecraftAppRegistrationException(403);
}

void main() {
  late Directory directory;
  late LauncherController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-login-dialog-');
    controller = LauncherController(
      supportDirectory: directory.path,
      platform: const HostPlatform('windows', 'x86_64'),
      authFactory: RejectedRegistrationAuth.new,
    );
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });
  testWidgets('rejected app shows help without recording an account', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: const LauncherColors(false).material,
        home: FTheme(
          data: const LauncherColors(false).forui,
          child: Scaffold(body: MicrosoftLoginDialog(controller: controller)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(MinecraftAppRegistrationException.message),
      findsOneWidget,
    );
    expect(find.text('查看服务说明'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.textContaining('Bad state:'), findsNothing);
    expect(find.text('复制验证码'), findsNothing);
    expect(controller.accounts, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
