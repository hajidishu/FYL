import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/data_directory.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/launcher_runtime.dart';
import 'package:free_your_launcher/ui/settings_page.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporary;
  late DataDirectoryManager manager;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-storage-ui-');
    manager = DataDirectoryManager(
      installationDirectory: p.join(temporary.path, 'program'),
    );
  });
  tearDown(() async => temporary.delete(recursive: true));

  for (final size in [const Size(800, 600), const Size(1180, 780)]) {
    testWidgets(
      'data settings fit $size and save the selected migration option',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = p.join(temporary.path, 'current');
        final target = p.join(temporary.path, 'chosen');
        String? chosen;
        bool? migration;
        final controller = LauncherController(
          supportDirectory: source,
          platform: const HostPlatform('windows', 'x86_64'),
          dataDirectories: manager,
          onDataDirectoryChange: (directory, migrate) async {
            chosen = directory;
            migration = migrate;
          },
        );
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: const LauncherColors(true).material,
            home: FTheme(
              data: const LauncherColors(true).forui,
              child: Scaffold(
                body: SettingsPage(controller: controller, onDirty: (_) {}),
              ),
            ),
          ),
        );
        await tester.tap(find.text('数据存储'));
        await tester.pumpAndSettle();
        expect(find.text(source), findsWidgets);
        final input = find.descendant(
          of: find.byKey(const ValueKey('settings-field-dataDirectory')),
          matching: find.byType(EditableText),
        );
        await tester.ensureVisible(input);
        await tester.enterText(input, target);
        await tester.ensureVisible(
          find.byKey(const ValueKey('migrate-launcher-data')),
        );
        await tester.tap(find.byKey(const ValueKey('migrate-launcher-data')));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('保存修改'));
          await Future<void>.delayed(const Duration(milliseconds: 40));
        });
        await tester.pumpAndSettle();
        expect(find.text('切换数据目录'), findsOneWidget);
        expect(find.textContaining('当前数据不会迁移'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('应用并重新加载'));
        });
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (chosen == null && DateTime.now().isBefore(deadline)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(chosen, target);
        expect(migration, isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'fresh runtime opens portable data and switches profiles without process restart',
    (tester) async {
      final loaded = <LauncherController>[];
      await tester.runAsync(() async {
        await tester.pumpWidget(
          LauncherRuntime(
            directories: manager,
            platform: const HostPlatform('windows', 'x86_64'),
            nativeWindow: false,
            legacyDirectory: () => null,
            onReady: (controller) {
              loaded.add(controller);
            },
          ),
        );
      });
      final startupDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (loaded.isEmpty && DateTime.now().isBefore(startupDeadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(loaded, hasLength(1));
      await tester.pumpAndSettle();
      expect(find.byType(LauncherApp), findsOneWidget);
      expect(loaded.single.supportDirectory, manager.defaultDirectory);
      await tester.runAsync(
        () => loaded.single.addOfflineAccount('Moved_User'),
      );
      final target = p.join(temporary.path, 'custom-profile');
      var completed = false;
      Object? failure;
      unawaited(
        loaded.single
            .changeDataDirectory(target, migrate: true)
            .then(
              (_) {
                completed = true;
              },
              onError: (Object error) {
                failure = error;
                completed = true;
              },
            ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!completed && DateTime.now().isBefore(deadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(failure, isNull);
      expect(completed, isTrue);
      await tester.pumpAndSettle();
      expect(loaded.length, 2);
      expect(
        loaded.last.supportDirectory,
        target,
        reason: loaded.last.errorMessage,
      );
      expect(loaded.last.activeAccount!.username, 'Moved_User');
      expect(
        await tester.runAsync(
          () => Directory(manager.defaultDirectory).exists(),
        ),
        isFalse,
      );
      expect(find.byType(LauncherApp), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
    },
  );

  for (final migrate in [true, false]) {
    testWidgets('legacy startup honors automatic migration = $migrate', (
      tester,
    ) async {
      final oldPath = p.join(temporary.path, 'legacy-appdata');
      await tester.runAsync(() async {
        final old = LauncherController(
          supportDirectory: oldPath,
          platform: const HostPlatform('windows', 'x86_64'),
        );
        await old.addOfflineAccount('Legacy_User');
        old.dispose();
      });
      LauncherController? active;
      await tester.pumpWidget(
        LauncherRuntime(
          directories: manager,
          platform: const HostPlatform('windows', 'x86_64'),
          nativeWindow: false,
          legacyDirectory: () => oldPath,
          onReady: (controller) => active = controller,
        ),
      );
      final promptDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.text('迁移旧版数据').evaluate().isEmpty &&
          DateTime.now().isBefore(promptDeadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(find.text('迁移旧版数据'), findsOneWidget);
      if (!migrate) {
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
      }
      await tester.ensureVisible(find.text('继续'));
      await tester.tap(find.text('继续'));
      await tester.pump(const Duration(milliseconds: 200));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (active == null && DateTime.now().isBefore(deadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(active, isNotNull);
      expect(active!.accounts.length, migrate ? 1 : 0);
      if (migrate) expect(active!.activeAccount!.username, 'Legacy_User');
      expect(
        await tester.runAsync(() => Directory(oldPath).exists()),
        !migrate,
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      expect(tester.takeException(), isNull);
    });
  }
}
