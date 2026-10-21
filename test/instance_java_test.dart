import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/java_discovery.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/instance_java_dialog.dart';

class InstanceJavaDiscovery extends JavaDiscovery {
  InstanceJavaDiscovery() : super(const HostPlatform('windows', 'x86_64'));

  @override
  Future<List<JavaInstallation>> discover({
    List<String> runtimeRoots = const [],
    String? selectedJava,
    void Function(JavaScanProgress)? onProgress,
  }) async => [
    JavaInstallation(
      executable: r'C:\Program Files\Java\jdk-21\bin\java.exe',
      version: '21.0.7',
      major: 21,
      architecture: 'x86_64',
      vendor: 'OpenJDK',
      home: r'C:\Program Files\Java\jdk-21',
      sources: {'PATH'},
    ),
  ];
}

void main() {
  late Directory temporary;
  late LauncherController controller;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-instance-java-');
    controller = LauncherController(
      supportDirectory: temporary.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    for (final id in ['first', 'second']) {
      controller.instances.add(
        GameInstance(
          id: id,
          name: id,
          version: '1.21.1',
          root: temporary.path,
          isolated: true,
          javaMajor: 21,
          managedJava: 'managed-$id',
          components: 'Fabric 0.16.10',
        ),
      );
    }
  });

  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });

  test(
    'instance Java persists separately and overrides changing defaults',
    () async {
      final original = controller.instances.first;
      const custom = r'C:\Java\jdk-21\bin\java.exe';
      await controller.saveInstanceJava(
        'first',
        InstanceJavaMode.custom,
        custom,
      );
      await controller.saveSettings(
        controller.settings.copy()
          ..automaticJava = false
          ..javaPath = 'default-java',
      );
      expect(
        controller.instances.first.javaExecutable(controller.settings),
        custom,
      );
      expect(
        controller.instances.last.javaExecutable(controller.settings),
        'default-java',
      );
      expect(controller.instances.first.metadataPath, original.metadataPath);
      expect(controller.instances.first.createdAt, original.createdAt);
      expect(controller.instances.first.components, original.components);

      final restored = LauncherController(
        supportDirectory: temporary.path,
        platform: controller.platform,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.instances.first.javaMode, InstanceJavaMode.custom);
      expect(
        restored.instances.first.javaExecutable(restored.settings),
        custom,
      );
      expect(restored.instances.last.javaMode, InstanceJavaMode.inherit);
      await restored.saveInstanceJava('second', InstanceJavaMode.automatic, '');
      expect(
        restored.instances.last.javaExecutable(restored.settings),
        'managed-second',
      );
      await restored.saveInstanceJava(
        'first',
        InstanceJavaMode.inherit,
        custom,
      );
      expect(
        restored.instances.first.javaExecutable(restored.settings),
        'default-java',
      );
      await expectLater(
        restored.saveInstanceJava('first', InstanceJavaMode.custom, '  '),
        throwsArgumentError,
      );
      expect(restored.instances.first.javaMode, InstanceJavaMode.inherit);
    },
  );

  test('legacy instances inherit Java defaults', () {
    final json = controller.instances.first.toJson()
      ..remove('javaMode')
      ..remove('javaPath');
    final legacy = GameInstance.fromJson(json);
    expect(legacy.javaMode, InstanceJavaMode.inherit);
    expect(legacy.javaExecutable(controller.settings), 'managed-first');
    controller.settings.automaticJava = false;
    controller.settings.javaPath = 'default-java';
    expect(legacy.javaExecutable(controller.settings), 'default-java');
  });

  for (final size in [const Size(800, 600), const Size(1180, 780)]) {
    testWidgets('instance Java discovery and cancel/save fit $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        LauncherApp(controller: controller, nativeWindow: false),
      );
      await tester.tap(find.byKey(const ValueKey('navigation-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('instance-java-first')));
      await tester.pumpAndSettle();
      expect(find.byType(InstanceJavaDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      final context = tester.element(find.text('版本管理').first);
      showDialog<bool>(
        context: context,
        builder: (_) => InstanceJavaDialog(
          controller: controller,
          instance: controller.instances.first,
          javaDiscovery: InstanceJavaDiscovery(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('instance-discover-java')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('使用此 Java'));
      await tester.tap(find.text('使用此 Java'));
      await tester.pumpAndSettle();
      expect(find.text('Java 21.0.7 · x64'), findsOneWidget);
      expect(controller.instances.first.javaMode, InstanceJavaMode.inherit);
      expect(controller.settings.automaticJava, isTrue);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('save-instance-java')));
        await controller.flush();
      });
      await tester.pumpAndSettle();
      expect(controller.instances.first.javaMode, InstanceJavaMode.custom);
      expect(controller.instances.last.javaMode, InstanceJavaMode.inherit);
      expect(controller.settings.javaPath, isEmpty);
      expect(find.byType(InstanceJavaDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
