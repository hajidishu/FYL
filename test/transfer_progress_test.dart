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
import 'package:free_your_launcher/ui/download_speed.dart';
import 'package:free_your_launcher/ui/pages.dart';

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
      expect(find.text('速度 0.0 KB/s'), findsOneWidget);
      task.bytes = 1024;
      expect(task.downloadRate.bytesPerSecond, greaterThan(0));
      task.bytes = 0;
      expect(task.downloadRate.bytesPerSecond, 0);
      for (final state in ContentTaskState.values.where(
        (s) => s != ContentTaskState.running,
      )) {
        task.state = state;
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
        expect(find.byType(DownloadSpeed), findsNothing);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('game download cards show speed only while running', (
    tester,
  ) async {
    final controller = LauncherController(
      supportDirectory: Directory.systemTemp.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    addTearDown(controller.dispose);
    final task =
        InstallTask(
            MinecraftVersion.fromJson({
              'id': '1.21.1',
              'type': 'release',
              'url': 'https://example.invalid/version',
              'releaseTime': '2024-01-01T00:00:00Z',
            }),
            'Test Game',
            controller.settings,
          )
          ..completedFiles = 1
          ..totalFiles = 2
          ..cachedBytes = 4096;
    controller.tasks.add(task);
    Widget harness() => MaterialApp(
      theme: const LauncherColors(false).material,
      home: FTheme(
        data: const LauncherColors(false).forui,
        child: Scaffold(
          body: DownloadsPage(controller: controller, navigate: (_) {}),
        ),
      ),
    );
    await tester.pumpWidget(harness());
    expect(find.text('速度 0.0 KB/s'), findsOneWidget);
    task.downloadedBytes = 1024;
    expect(task.downloadRate.bytesPerSecond, greaterThan(0));
    final speed = task.downloadRate.bytesPerSecond;
    task.downloadedBytes = 1024;
    expect(task.downloadRate.bytesPerSecond, lessThanOrEqualTo(speed));
    for (final status in TaskStatus.values.where(
      (s) => s != TaskStatus.running,
    )) {
      task.status = status;
      await tester.pumpWidget(harness());
      expect(find.byType(DownloadSpeed), findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
