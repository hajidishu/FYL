import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/build_info.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/multiplayer.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/multiplayer_page.dart';

class _NoMultiplayerController extends LauncherController {
  _NoMultiplayerController(String directory)
    : super(
        supportDirectory: directory,
        platform: const HostPlatform('windows', 'x86_64'),
      );

  @override
  MultiplayerController get multiplayer =>
      throw StateError('Disabled feature was initialized');
}

void main() {
  testWidgets(
    'the build flag controls navigation and multiplayer initialization',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('fyl-feature-'),
      );
      final controller = launcherMultiplayerEnabled
          ? LauncherController(
              supportDirectory: root!.path,
              platform: const HostPlatform('windows', 'x86_64'),
            )
          : _NoMultiplayerController(root!.path);
      await tester.runAsync(() async {
        await File(
          '${root.path}/multiplayer.json',
        ).writeAsString('{"localPort":45678}');
        await controller.initialize();
      });
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.pumpAndSettle();
      if (launcherMultiplayerEnabled) {
        expect(controller.multiplayer.settings.localPort, 45678);
        expect(find.byKey(const ValueKey('navigation-4')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('navigation-4')));
        await tester.pumpAndSettle();
        expect(find.byType(MultiplayerPage), findsOneWidget);
      } else {
        expect(find.byKey(const ValueKey('navigation-4')), findsNothing);
        expect(find.text('联机'), findsNothing);
        expect(find.byType(MultiplayerPage), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );

  test(
    'disabled builds cannot start a helper even through the controller',
    () async {
      var launches = 0;
      final controller = MultiplayerController(
        launch: (_, _) async {
          launches++;
          return null;
        },
      );
      addTearDown(controller.dispose);
      await expectLater(controller.host(), throwsUnsupportedError);
      expect(launches, 0);
      expect(controller.active, isFalse);
    },
    skip: launcherMultiplayerEnabled,
  );
}
