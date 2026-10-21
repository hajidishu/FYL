import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/java_discovery.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/ui/settings_page.dart';
import 'package:free_your_launcher/ui/theme.dart';

class FixtureJavaDiscovery extends JavaDiscovery {
  final List<JavaInstallation> results;
  FixtureJavaDiscovery(this.results)
    : super(const HostPlatform('windows', 'x86_64'));

  @override
  Future<List<JavaInstallation>> discover({
    List<String> runtimeRoots = const [],
    String? selectedJava,
    void Function(JavaScanProgress)? onProgress,
  }) async {
    onProgress?.call(JavaScanProgress(results.length, results.length));
    return results;
  }
}

void main() {
  testWidgets(
    'settings and Java scrollbar proportions stay stable while scrolling',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = LauncherController(
        supportDirectory: Directory.systemTemp.path,
        platform: const HostPlatform('windows', 'x86_64'),
      );
      final javas = List.generate(
        12,
        (index) => JavaInstallation(
          executable: 'C:\\Java\\jdk-${index + 8}\\bin\\java.exe',
          version: '${index + 8}.0.1',
          major: index + 8,
          architecture: 'x86_64',
          vendor: 'OpenJDK',
          home: 'C:\\Java\\jdk-${index + 8}',
          sources: {'PATH'},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: const LauncherColors(false).material,
          home: FTheme(
            data: const LauncherColors(false).forui,
            child: Scaffold(
              body: SettingsPage(
                controller: controller,
                javaDiscovery: FixtureJavaDiscovery(javas),
                onDirty: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('默认 Java 与内存').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('discover-java')));
      await tester.pumpAndSettle();
      final positions = tester
          .stateList<ScrollableState>(
            find.descendant(
              of: find.byType(SettingsPage),
              matching: find.byType(Scrollable),
            ),
          )
          .where(
            (state) =>
                state.widget.axisDirection == AxisDirection.down &&
                state.position.maxScrollExtent > 0,
          )
          .take(2)
          .map((state) => state.position)
          .toList();
      expect(positions, hasLength(2));
      double proportion(ScrollPosition position) =>
          position.viewportDimension /
          (position.maxScrollExtent -
              position.minScrollExtent +
              position.viewportDimension);
      final initial = {
        for (final position in positions) position: proportion(position),
      };
      for (final position in positions.reversed) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          proportion(position),
          closeTo(initial[position]!, .001),
          reason: 'Scrolling must not change the scrollbar thumb proportion',
        );
        position.jumpTo(position.minScrollExtent);
        await tester.pumpAndSettle();
        expect(proportion(position), closeTo(initial[position]!, .001));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
  for (final width in [800.0, 1180.0]) {
    testWidgets(
      'Java discovery is reachable in automatic mode and selects a runtime at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = LauncherController(
          supportDirectory: Directory.systemTemp.path,
          platform: const HostPlatform('windows', 'x86_64'),
        );
        final java = JavaInstallation(
          executable: r'C:\Program Files\Microsoft\jdk-21\bin\java.exe',
          version: '21.0.7',
          major: 21,
          architecture: 'x86_64',
          vendor: 'Microsoft',
          home: r'C:\Program Files\Microsoft\jdk-21',
          sources: {'系统安装目录'},
        );
        final state = GlobalKey<SettingsPageState>();
        await tester.pumpWidget(
          MaterialApp(
            theme: const LauncherColors(true).material,
            home: FTheme(
              data: const LauncherColors(true).forui,
              child: Scaffold(
                body: SettingsPage(
                  key: state,
                  controller: controller,
                  javaDiscovery: FixtureJavaDiscovery([java]),
                  onDirty: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('默认 Java 与内存').first);
        await tester.pumpAndSettle();
        expect(controller.settings.automaticJava, isTrue);
        await tester.tap(find.byKey(const ValueKey('discover-java')));
        await tester.pumpAndSettle();
        expect(find.text('Java 21.0.7 · x64'), findsOneWidget);
        expect(find.text('Microsoft · ${java.executable}'), findsOneWidget);
        expect(state.currentState!.dirty, isFalse);
        await tester.tap(find.text('使用此 Java'));
        await tester.pumpAndSettle();
        expect(state.currentState!.draft.automaticJava, isFalse);
        expect(state.currentState!.fields['javaPath']!.text, java.executable);
        expect(state.currentState!.dirty, isTrue);
        expect(controller.settings.automaticJava, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      },
    );
  }
}
