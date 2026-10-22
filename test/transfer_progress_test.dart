import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/ui/byte_size.dart';
import 'package:free_your_launcher/ui/content_tasks.dart';
import 'package:free_your_launcher/ui/theme.dart';

void main() {
  test('small transfers are not rounded down to zero megabytes', () {
    expect(formatByteSize(0), '0 B');
    expect(formatByteSize(512), '512 B');
    expect(formatByteSize(1024), '1.0 KB');
    expect(formatByteSize(1048576), '1.0 MB');
  });
  testWidgets(
    'a cached download reports cache reuse separately from network bytes',
    (tester) async {
      final controller = LauncherController(
        supportDirectory: Directory.systemTemp.path,
        platform: const HostPlatform('windows', 'x86_64'),
      );
      addTearDown(controller.dispose);
      final task =
          ContentTask('Cached Mod', ContentKind.mod, ContentSource.modrinth)
            ..cachedBytes = 4096
            ..total = 2
            ..done = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: const LauncherColors(false).material,
          home: FTheme(
            data: const LauncherColors(false).forui,
            child: Scaffold(
              body: ContentTaskCard(controller: controller, task: task),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('已传输 0 B · 复用缓存 4.0 KB'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
