import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/community_page.dart';
import 'package:free_your_launcher/ui/file_drop.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native file-drop channel and community resource pages',
    (tester) async {
      await windowManager.ensureInitialized();
      await windowManager.setSize(const Size(1180, 780));
      final temporary = await Directory.systemTemp.createTemp(
        'fyl-native-drop-',
      );
      final controller = LauncherController(
        supportDirectory: temporary.path,
        platform: await HostPlatform.detect(),
      );
      await controller.initialize();
      final instance = GameInstance(
        id: 'native-drop',
        name: 'Native Drop Test',
        version: '1.21.1',
        root: controller.settings.gameRoot,
        isolated: true,
        javaMajor: 21,
        components: 'Fabric 0.16.10',
      );
      controller.instances.add(instance);
      controller.selectedId = instance.id;
      final world = File(
        p.join(instance.gameDirectory, 'saves', 'World', 'level.dat'),
      );
      await world.parent.create(recursive: true);
      await world.writeAsString('test-world');
      final source = File(p.join(temporary.path, 'native-mod.jar'));
      await source.writeAsBytes(
        ZipEncoder().encode(
          Archive()..addFile(
            ArchiveFile.string(
              'fabric.mod.json',
              '{"id":"native_test","version":"1"}',
            ),
          ),
        ),
      );
      final pack = File(p.join(temporary.path, 'native-pack.mrpack'));
      await pack.writeAsBytes(
        ZipEncoder().encode(
          Archive()..addFile(
            ArchiveFile.string(
              'modrinth.index.json',
              '{"formatVersion":1,"game":"minecraft","name":"Native Pack","versionId":"1","dependencies":{"minecraft":"1.21.1"},"files":[]}',
            ),
          ),
        ),
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: LauncherApp(controller: controller, nativeWindow: false),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> screenshot(String name) async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          p.join(Directory.current.path, 'build', 'screenshots', '$name.png'),
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
        expect(tester.takeException(), isNull);
      }

      Future<void> event(String method, Object args) async {
        final done = Completer<void>();
        ui.channelBuffers.push(
          'desktop_drop',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, args),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await tester.pump();
      }

      Future<void> waitFor(Finder finder) async {
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(finder, findsWidgets, reason: controller.errorMessage);
      }

      Future<void> waitForImport() async {
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (tester
                .state<FileDropRegionState>(find.byType(FileDropRegion))
                .busy &&
            DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          tester.state<FileDropRegionState>(find.byType(FileDropRegion)).busy,
          isFalse,
        );
      }

      if (Platform.isWindows) {
        expect(
          await File(
            p.join(
              p.dirname(Platform.resolvedExecutable),
              'desktop_drop_plugin.dll',
            ),
          ).exists(),
          isTrue,
        );
      }
      await event('entered', <double>[350, 250]);
      expect(find.text('松开以安装 Mod 或整合包'), findsOneWidget);
      await screenshot('file-drop-overlay');
      await event('performOperation', [source.path]);
      await waitFor(find.byType(ModImportDialog));
      expect(
        tester
            .widget<SelectBox<String>>(find.byType(SelectBox<String>).last)
            .value,
        instance.id,
      );
      await screenshot('file-drop-mod-confirm');
      await tester.tap(find.byKey(const ValueKey('confirm-dropped-mods')));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      final installed = File(
        p.join(instance.gameDirectory, 'mods', 'native-mod.jar'),
      );
      while (!await installed.exists() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(await installed.exists(), isTrue);
      await waitForImport();
      expect(controller.errorMessage, isNull);
      await event('entered', <double>[350, 250]);
      await event('performOperation', [pack.path]);
      await waitFor(find.byType(PackInstallDialog));
      expect(controller.content.tasks, isEmpty);
      await screenshot('file-drop-pack-confirm');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await waitForImport();
      expect(controller.instances, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('navigation-2')));
      await tester.pumpAndSettle();
      for (final (kind, label) in [
        (ContentKind.datapack, '数据包'),
        (ContentKind.resourcepack, '资源包'),
        (ContentKind.shader, '光影包'),
      ]) {
        await tester.tap(find.text(label));
        await tester.pump();
        await waitFor(find.byType(ProjectIcon));
        await screenshot('community-${kind.name}');
        final project = tester
            .widget<ProjectIcon>(find.byType(ProjectIcon).first)
            .project;
        expect(project.kind, kind);
        await tester.tap(find.text(project.name));
        await tester.pump();
        final action = find.byWidgetPredicate(
          (widget) =>
              widget is AppButton &&
              '${widget.key}'.contains('install-content-'),
        );
        await waitFor(action);
        await screenshot('community-${kind.name}-versions');
        if (kind == ContentKind.datapack) {
          await tester.ensureVisible(action.first);
          await tester.tap(action.first);
          await waitFor(find.byType(DataPackWorldDialog));
          await screenshot('datapack-world-picker');
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
        }
      }
      expect(controller.content.tasks, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await temporary.delete(recursive: true);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
