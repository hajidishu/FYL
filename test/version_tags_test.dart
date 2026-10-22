import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/instance_details.dart';

GameInstance game({
  String components = '',
  String category = '',
  Json installation = const {},
  String? directory,
}) => GameInstance(
  id: 'game',
  name: 'Game',
  version: '1.21.1',
  root: directory ?? Directory.systemTemp.path,
  isolated: true,
  javaMajor: 21,
  components: components,
  category: category,
  installation: installation,
);

void main() {
  test('automatic tags identify loaders and preserve custom labels', () {
    for (final loader in ['Forge', 'NeoForge', 'Fabric', 'Quilt', 'OptiFine']) {
      expect(game(components: '$loader 1.0').displayTag, loader);
    }
    expect(game().displayTag, '原版');
    expect(
      game(
        components: 'Fabric 0.16',
        installation: {'modpack': true},
      ).displayTag,
      '整合包',
    );
    expect(
      game(
        components: 'Forge 47',
        installation: {
          'loader': {'type': 'fabric'},
        },
      ).displayTag,
      'Fabric',
    );
    final custom = game(components: 'Fabric 0.16', category: '日常生存');
    expect(GameInstance.fromJson(custom.toJson()).displayTag, '日常生存');
    expect(custom.copyWith(category: '').displayTag, 'Fabric');
  });
  testWidgets('a user can edit the displayed version tag in version settings', (
    tester,
  ) async {
    final root = await tester.runAsync(
      () => Directory.systemTemp.createTemp('fyl-tags-'),
    );
    final controller = LauncherController(
      supportDirectory: root!.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    controller.instances.add(
      game(components: 'Fabric 0.16', directory: root.path),
    );
    await tester.pumpWidget(
      LauncherApp(controller: controller, nativeWindow: false),
    );
    await tester.tap(find.byKey(const ValueKey('navigation-1')));
    await tester.pumpAndSettle();
    expect(find.text('Fabric'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('instance-settings-game')));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const ValueKey('instance-field-category')),
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(field);
    await tester.enterText(field, '日常生存');
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(InstanceDetailsPage));
    await tester.runAsync(() async {
      await state.save();
    });
    await tester.pumpAndSettle();
    expect(controller.instances.single.displayTag, '日常生存');
    await tester.tap(find.byTooltip('返回版本列表'));
    await tester.pumpAndSettle();
    expect(find.text('日常生存'), findsOneWidget);
    expect(find.text('Fabric'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
