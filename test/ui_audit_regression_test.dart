import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/local_mods.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/ui/instance_details.dart';
import 'package:free_your_launcher/ui/instance_mods.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:path/path.dart' as p;

class TestLauncherController extends LauncherController {
  bool delayModUpdates = false;
  final modUpdateGate = Completer<void>();

  TestLauncherController({
    required super.supportDirectory,
    required super.platform,
  });

  @override
  Future<void> updateMods(
    String id,
    List<LocalMod> mods, {
    bool? enabled,
    bool remove = false,
  }) async {
    if (delayModUpdates) {
      await modUpdateGate.future;
      return;
    }
    await super.updateMods(id, mods, enabled: enabled, remove: remove);
  }
}

void main() {
  late Directory temporary;
  late TestLauncherController controller;
  late GameInstance instance;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-ui-audit-');
    controller = TestLauncherController(
      supportDirectory: temporary.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    instance = GameInstance(
      id: 'target',
      name: 'Target',
      version: '1.21.1',
      root: temporary.path,
      isolated: true,
      javaMajor: 21,
      launchSettings: const InstanceLaunchSettings(
        maxMemory: 4096,
        width: 1600,
        jvmArguments: '-Xmx4G',
      ),
    );
    controller.instances.add(instance);
  });

  tearDown(() async {
    controller.dispose();
    await temporary.delete(recursive: true);
  });

  Widget harness(Widget child) => MaterialApp(
    theme: const LauncherColors(false).material,
    home: FTheme(
      data: const LauncherColors(false).forui,
      child: Scaffold(body: child),
    ),
  );

  Finder edit(String key) => find.descendant(
    of: find.byKey(ValueKey('instance-field-$key')),
    matching: find.byType(EditableText),
  );

  Future<void> addMod(String name) async {
    final metadata = utf8.encode(
      jsonEncode({
        'id': name.toLowerCase(),
        'name': name,
        'version': '1.0',
        'description': '$name fixture',
      }),
    );
    final archive = Archive()
      ..addFile(ArchiveFile('fabric.mod.json', metadata.length, metadata));
    final file = File(
      p.join(instance.gameDirectory, 'mods', '${name.toLowerCase()}.jar'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(ZipEncoder().encode(archive));
  }

  testWidgets(
    'turning off and resetting instance overrides shows inherited values',
    (tester) async {
      await tester.pumpWidget(
        harness(
          InstanceDetailsPage(
            controller: controller,
            instanceId: instance.id,
            onBack: () {},
            onDirty: (_) {},
            navigate: (_) {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('instance-tab-1')));
      await tester.pumpAndSettle();

      controller.settings.automaticMemory = false;
      await tester.tap(find.byKey(const ValueKey('instance-memory-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跟随默认设置').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(edit('maxMemory')).controller.text,
        '2048',
      );
      expect(
        tester.widget<EditableText>(edit('width')).controller.text,
        '1600',
      );
      expect(
        tester.widget<EditableText>(edit('jvmArguments')).controller.text,
        '-Xmx4G',
      );

      await tester.tap(find.byKey(const ValueKey('instance-memory-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动配置').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(edit('maxMemory')).controller.text,
        '4096',
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('reset-instance-launch-options')),
      );
      await tester.tap(
        find.byKey(const ValueKey('reset-instance-launch-options')),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(edit('maxMemory')).controller.text,
        '2048',
      );
      expect(
        tester.widget<EditableText>(edit('width')).controller.text,
        '1280',
      );
      expect(
        tester.widget<EditableText>(edit('jvmArguments')).controller.text,
        controller.settings.jvmArguments,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('saving is disabled while another instance operation is active', (
    tester,
  ) async {
    controller.instanceOperation = 'repair in progress';
    await tester.pumpWidget(
      harness(
        InstanceDetailsPage(
          controller: controller,
          instanceId: instance.id,
          onBack: () {},
          onDirty: (_) {},
          navigate: (_) {},
        ),
      ),
    );
    await tester.enterText(edit('name'), 'Changed');
    await tester.pumpAndSettle();
    final save = tester.widget<AppButton>(
      find.byKey(const ValueKey('save-instance-settings')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets(
    'select all follows visible mod paths and preserves hidden picks',
    (tester) async {
      await tester.runAsync(() async {
        await addMod('Alpha');
        await addMod('Beta');
      });
      await tester.pumpWidget(
        harness(
          SizedBox.expand(
            child: InstanceMods(
              controller: controller,
              instance: instance,
              onDownload: () {},
            ),
          ),
        ),
      );
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 10));
        if (find.byType(Checkbox).evaluate().length == 2) break;
      }
      expect(find.byType(Checkbox), findsNWidgets(2));

      await tester.enterText(find.byType(EditableText).first, 'Alpha');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-visible-mods')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText).first, 'Beta');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-visible-mods')));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);

      await tester.enterText(find.byType(EditableText).first, 'Alpha');
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      expect(find.textContaining('2 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mod operation may finish safely after its page is removed', (
    tester,
  ) async {
    await tester.runAsync(() => addMod('Alpha'));
    controller.delayModUpdates = true;
    await tester.pumpWidget(
      harness(
        SizedBox.expand(
          child: InstanceMods(
            controller: controller,
            instance: instance,
            onDownload: () {},
          ),
        ),
      ),
    );
    for (var attempt = 0; attempt < 30; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 10));
      if (find.byType(Switch).evaluate().isNotEmpty) break;
    }
    expect(find.byType(Switch), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.modUpdateGate.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
