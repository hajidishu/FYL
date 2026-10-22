import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/version_groups.dart';
import 'package:free_your_launcher/ui/game_versions.dart';
import 'package:free_your_launcher/ui/theme.dart';

MinecraftVersion version(String id, String type) => MinecraftVersion.fromJson({
  'id': id,
  'type': type,
  'url': 'https://example.invalid/version',
  'releaseTime': '2026-04-01T00:00:00Z',
});

void main() {
  test(
    'official version categories separate jokes from normal releases and previews',
    () {
      expect(version('26.1.1', 'release').group, MinecraftVersionGroup.release);
      expect(
        version('26.4-snapshot-5', 'snapshot').group,
        MinecraftVersionGroup.preview,
      );
      expect(
        version('1.21.1-rc1', 'snapshot').group,
        MinecraftVersionGroup.preview,
      );
      expect(
        version('b1.7.3', 'old_beta').group,
        MinecraftVersionGroup.historical,
      );
      expect(
        version('c0.30_01c', 'old_alpha').group,
        MinecraftVersionGroup.historical,
      );
      for (final id in [
        '15w14a',
        '1.RV-Pre1',
        '3D Shareware v1.34',
        '20w14infinite',
        '22w13oneblockatatime',
        '23w13a_or_b',
        '24w14potato',
        '25w14craftmine',
        '26w14a',
      ]) {
        expect(
          version(id, 'snapshot').group,
          MinecraftVersionGroup.aprilFools,
          reason: id,
        );
      }
    },
  );
  testWidgets(
    'every category is accessible and searching a joke keeps the correct installation target',
    (tester) async {
      final controller = LauncherController(
        supportDirectory: Directory.systemTemp.path,
        platform: const HostPlatform('windows', 'x86_64'),
      );
      addTearDown(controller.dispose);
      controller.versions.addAll([
        version('26.3', 'release'),
        version('26.4-snapshot-5', 'snapshot'),
        version('b1.7.3', 'old_beta'),
        version('26w14a', 'snapshot'),
      ]);
      controller.latestRelease = '26.3';
      controller.latestSnapshot = '26.4-snapshot-5';
      MinecraftVersion? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: const LauncherColors(false).material,
          home: FTheme(
            data: const LauncherColors(false).forui,
            child: Scaffold(
              body: GameVersionList(
                controller: controller,
                onInstall: (v) => selected = v,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最新版本'), findsOneWidget);
      expect(find.text('最新预览版'), findsOneWidget);
      for (final group in MinecraftVersionGroup.values) {
        expect(
          find.byKey(ValueKey('version-group-${group.name}')),
          findsOneWidget,
        );
      }
      await tester.enterText(find.byType(EditableText).first, '26w14a');
      await tester.pumpAndSettle();
      expect(find.text('愚人节版 (1)'), findsOneWidget);
      expect(find.text('最新预览版'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('install-version-26w14a')));
      await tester.pumpAndSettle();
      expect(selected?.id, '26w14a');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
