import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/install_options.dart';
import 'package:free_your_launcher/core/mod_catalog.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/ui/install_page.dart';
import 'package:free_your_launcher/ui/theme.dart';

class FixtureCatalog extends ModCatalog {
  FixtureCatalog()
    : super(
        OfficialNetwork(LauncherSettings(gameRoot: Directory.systemTemp.path)),
      );
  @override
  Future<List<LoaderVersion>> loaders(
    ModLoader kind,
    String minecraft,
    CancellationToken token,
  ) async => [
    LoaderVersion(kind, switch (kind) {
      ModLoader.forge => '47.3.0',
      ModLoader.neoforge => '20.1.0',
      ModLoader.fabric => '0.16.10',
    }),
  ];
  @override
  Future<List<OptiFineVersion>> optifine(
    String minecraft,
    CancellationToken token,
  ) async => [const OptiFineVersion('OptiFine_1.20.1_HD_U_I6.jar')];
  @override
  Future<List<CompatibilityMod>> optifabric(
    String minecraft,
    CancellationToken token,
  ) async => [
    const CompatibilityMod(
      version: '1.14.3',
      fileName: 'optifabric.jar',
      url: 'https://mediafilez.forgecdn.net/test.jar',
    ),
  ];
}

void main() {
  testWidgets(
    'installer replaces other loaders, warns about OptiFine and requires OptiFabric',
    (tester) async {
      tester.view.physicalSize = const Size(1180, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = LauncherController(
        supportDirectory: Directory.systemTemp.path,
        platform: const HostPlatform('windows', 'x86_64'),
      );
      final catalog = FixtureCatalog();
      InstallOptions? selected;
      final version = MinecraftVersion.fromJson({
        'id': '1.20.1',
        'type': 'release',
        'url': 'https://piston-meta.mojang.com/test.json',
        'releaseTime': '2023-06-12T00:00:00Z',
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: const LauncherColors(false).material,
          home: FTheme(
            data: const LauncherColors(false).forui,
            child: Scaffold(
              body: InstallPage(
                controller: controller,
                version: version,
                catalog: catalog,
                onBack: () {},
                onInstall: (_, options) => selected = options,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forge'));
      await tester.pumpAndSettle();
      expect(find.text('最新版本'), findsOneWidget);
      expect(find.text('全部版本 (1)'), findsOneWidget);
      await tester.tap(find.text('47.3.0').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Fabric'));
      await tester.tap(find.text('Fabric'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('0.16.10').first);
      await tester.tap(find.text('0.16.10').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('OptiFine'));
      await tester.tap(find.text('OptiFine'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('1.20.1 HD U I6').first);
      await tester.tap(find.text('1.20.1 HD U I6').first);
      await tester.pumpAndSettle();
      expect(find.text('Fabric 与 OptiFine 存在兼容性问题'), findsOneWidget);
      final start = find.widgetWithText(FButton, '开始安装');
      expect(tester.widget<FButton>(start).onPress, isNull);
      await tester.ensureVisible(find.text('OptiFabric'));
      await tester.tap(find.text('OptiFabric'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('1.14.3').first);
      await tester.tap(find.text('1.14.3').first);
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(selected!.loader!.loader, ModLoader.fabric);
      expect(selected!.optifabric!.version, '1.14.3');
      expect(selected!.optifine, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      catalog.network.close();
    },
  );
}
