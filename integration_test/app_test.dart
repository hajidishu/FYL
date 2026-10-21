import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/account_store.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/core/minecraft.dart'
    show versionManifestUrl, MinecraftRunner;
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/install_page.dart';
import 'package:free_your_launcher/ui/settings_page.dart';
import 'package:free_your_launcher/ui/instance_java_dialog.dart';
import 'package:free_your_launcher/core/community_models.dart';
import 'package:free_your_launcher/ui/community_page.dart';
import 'package:free_your_launcher/ui/theme.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('desktop flows and screenshots', (tester) async {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1180, 780));
    final temporary = await Directory.systemTemp.createTemp('fyl-ui-');
    final controller = LauncherController(
      supportDirectory: temporary.path,
      platform: await HostPlatform.detect(),
    );
    await controller.initialize();
    // Verify the native credential backend with disposable test data only.
    final credentialStore = SecureAccountTokenStore(
      supportDirectory: temporary.path,
    );
    final credentialId = 'integration-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await credentialStore.write(
        credentialId,
        AccountTokens(
          refreshToken: 'test-refresh',
          accessToken: 'test-access',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
          clientId: 'test-client',
        ),
      );
      expect(
        (await credentialStore.read(credentialId))!.refreshToken,
        'test-refresh',
      );
    } finally {
      await credentialStore.delete(credentialId);
    }
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
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final file = File(
        p.join(Directory.current.path, 'build', 'screenshots', '$name.png'),
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.buffer.asUint8List());
      image.dispose();
    }

    expect(find.text('选择游戏版本和账号。'), findsOneWidget);
    await tester.tap(find.text('添加账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加离线账号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'Launcher_Test');
    await tester.tap(find.text('创建并使用'));
    await controller.flush();
    await tester.pumpAndSettle();
    expect(controller.activeAccount!.username, 'Launcher_Test');
    controller.accounts.add(
      const LauncherAccount(
        id: 'microsoft:demo',
        kind: AccountKind.microsoft,
        username: 'Online_Demo',
        uuid: '12345678901234567890123456789012',
      ),
    );
    controller.notifyListeners();
    await tester.pumpAndSettle();
    await screenshot('home');
    await tester.tap(find.text('添加账号'));
    await tester.pumpAndSettle();
    expect(find.text('正版账号'), findsOneWidget);
    await screenshot('accounts');
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();
    controller.settings.theme = 'light';
    controller.notifyListeners();
    await tester.pumpAndSettle();
    await screenshot('home-light');
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('navigation-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('游戏与隔离'));
    await tester.pumpAndSettle();
    expect(find.text('新版本默认启用版本隔离'), findsOneWidget);
    await screenshot('settings');
    await tester.tap(find.text('默认 Java 与内存').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('discover-java')));
    final settingsState = tester.state<SettingsPageState>(
      find.byType(SettingsPage),
    );
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (settingsState.scanningJava && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    await tester.pumpAndSettle();
    expect(settingsState.scanningJava, isFalse);
    expect(settingsState.javaScanned, isTrue);
    final compatible = settingsState.installations.where(
      (java) => java.architecture == controller.platform.arch,
    );
    if (compatible.isNotEmpty) {
      final java = compatible.first;
      settingsState.useJava(java);
      await settingsState.save();
      await tester.pumpAndSettle();
      expect(controller.settings.automaticJava, isFalse);
      expect(controller.settings.javaPath, java.executable);
      final restored = LauncherController(
        supportDirectory: temporary.path,
        platform: controller.platform,
      );
      await restored.initialize();
      expect(restored.settings.javaPath, java.executable);
      restored.dispose();
    }
    await screenshot('java-settings');
    final instanceJava = compatible.isEmpty ? null : compatible.first;
    final instance = GameInstance(
      id: 'desktop-java-check',
      name: 'Adventure · Fabric',
      version: '1.21.1',
      root: temporary.path,
      isolated: true,
      javaMajor: instanceJava?.major ?? 21,
      components: 'Fabric 0.16.10',
    );
    controller.instances.add(instance);
    controller.notifyListeners();
    await tester.tap(find.byKey(const ValueKey('navigation-1')));
    await tester.pumpAndSettle();
    await screenshot('instances');
    await tester.tap(
      find.byKey(const ValueKey('instance-java-desktop-java-check')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随默认 Java'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('指定 Java').last);
    await tester.pumpAndSettle();
    final javaInput = find.descendant(
      of: find.byKey(const ValueKey('instance-java-path')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(javaInput, instanceJava?.executable ?? 'java');
    await tester.pumpAndSettle();
    await screenshot('instance-java');
    await tester.tap(find.byKey(const ValueKey('save-instance-java')));
    await controller.flush();
    await tester.pumpAndSettle();
    expect(find.byType(InstanceJavaDialog), findsNothing);
    expect(controller.instances.single.javaMode, InstanceJavaMode.custom);
    if (instanceJava != null) {
      expect(
        await MinecraftRunner(
          controller.platform,
        ).javaFor(controller.instances.single, controller.settings),
        instanceJava.executable,
      );
    }
    await screenshot('instances');
    await tester.tap(find.byKey(const ValueKey('navigation-2')));
    await tester.pumpAndSettle();
    expect(find.text('版本列表'), findsOneWidget);
    await screenshot('downloads');
    final network = OfficialNetwork(
      controller.settings.copy()
        ..downloadRetries = 0
        ..timeoutSeconds = 15,
    );
    final manifest = await network.json(versionManifestUrl);
    final chosen =
        (manifest['versions'] as List<dynamic>).firstWhere(
              (row) => row['id'] == '1.20.1',
            )
            as Json;
    final latestId = (manifest['latest'] as Json)['release'] as String;
    final latest =
        (manifest['versions'] as List<dynamic>).firstWhere(
              (row) => row['id'] == latestId,
            )
            as Json;
    network.close();
    controller.latestRelease = latestId;
    controller.versions.add(MinecraftVersion.fromJson(latest));
    controller.versions.add(MinecraftVersion.fromJson(chosen));
    controller.notifyListeners();
    await tester.pumpAndSettle();
    await screenshot('downloads');
    final install = find.byKey(const ValueKey('install-version-1.20.1'));
    await tester.ensureVisible(install);
    await tester.pumpAndSettle();
    await tester.tap(install);
    await tester.pump();
    final loadDeadline = DateTime.now().add(const Duration(seconds: 90));
    while (find.text('正在读取版本…').evaluate().isNotEmpty &&
        DateTime.now().isBefore(loadDeadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
    expect(find.byType(InstallPage), findsOneWidget);
    await screenshot('install-components');
    await tester.tap(find.text('Forge'));
    await tester.pumpAndSettle();
    await screenshot('install-forge-items');
    await tester.tap(find.text('Forge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fabric'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('0.15.11'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0.15.11'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('OptiFine'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OptiFine'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('1.20.1 HD U I6').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.20.1 HD U I6').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('OptiFabric'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OptiFabric'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('1.14.3').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.14.3').first);
    await tester.pumpAndSettle();
    expect(find.text('Fabric 与 OptiFine 存在兼容性问题'), findsOneWidget);
    await tester.ensureVisible(find.text('Fabric 与 OptiFine 存在兼容性问题'));
    await tester.pumpAndSettle();
    await screenshot('install-compatibility');
    await tester.tap(find.byTooltip('返回版本列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mod'));
    Future<void> waitForCommunity() async {
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (find.text('正在搜索…').evaluate().isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pumpAndSettle();
    }

    Future<void> waitForContentVersions() async {
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (find
              .byWidgetPredicate(
                (w) =>
                    w is AppButton && '${w.key}'.contains('install-content-'),
              )
              .evaluate()
              .isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pumpAndSettle();
    }

    await tester.pump();
    await waitForCommunity();
    expect(find.byType(ProjectIcon), findsWidgets);
    await screenshot('community-mods');
    final modProject = tester
        .widget<ProjectIcon>(find.byType(ProjectIcon).first)
        .project;
    await tester.ensureVisible(find.text(modProject.name));
    await tester.pumpAndSettle();
    await tester.tap(find.text(modProject.name));
    await tester.pump();
    await waitForContentVersions();
    await screenshot('community-mod-versions');
    if (Platform.isWindows) {
      final output = p.join(
        Directory.current.path,
        'build',
        'native-mod-save',
        'chosen-mod.jar',
      );
      if (await File(output).exists()) await File(output).delete();
      final helper = await Process.start('powershell.exe', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(
          Directory.current.path,
          'integration_test',
          'native_save_dialog.ps1',
        ),
        '-OwnerPid',
        '$pid',
        '-ExpectedExecutable',
        p.join(
          Directory.current.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Debug',
          'free_your_launcher.exe',
        ),
        '-OutputPath',
        output,
      ]);
      final helperOutput = helper.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final helperErrors = helper.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      var helperFinished = false;
      final helperExit = helper.exitCode.then((code) {
        helperFinished = true;
        return code;
      });
      final action = find
          .byWidgetPredicate(
            (w) => w is AppButton && '${w.key}'.contains('install-content-'),
          )
          .first;
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pump();
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (((controller.content.tasks.isEmpty && !helperFinished) ||
              controller.content.tasks.isNotEmpty &&
                  controller.content.tasks.first.state ==
                      ContentTaskState.running) &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      await tester.pumpAndSettle();
      await screenshot('community-save-result');
      final visibleErrors = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data)
          .join('\n');
      expect(
        await helperExit,
        0,
        reason: '${await helperErrors}\n$visibleErrors',
      );
      expect(await helperOutput, contains('"nativeDialog":true'));
      expect(
        controller.content.tasks.first.state,
        ContentTaskState.completed,
        reason: controller.content.tasks.first.error,
      );
      expect(await File(output).exists(), isTrue);
      await screenshot('community-mod-installed');
    }
    await tester.tap(find.text('整合包'));
    await tester.pump();
    await waitForCommunity();
    await tester.enterText(
      find.byType(EditableText).at(0),
      'Fabulously Optimized',
    );
    await tester.enterText(find.byType(EditableText).at(1), '1.21.1');
    await tester.tap(find.byKey(const ValueKey('search-community')));
    await tester.pump();
    await waitForCommunity();
    await screenshot('community-packs');
    await tester.ensureVisible(find.text('Fabulously Optimized').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fabulously Optimized').last);
    await tester.pump();
    await waitForContentVersions();
    await screenshot('community-pack-versions');
    final packAction = find
        .byWidgetPredicate(
          (w) => w is AppButton && '${w.key}'.contains('install-content-'),
        )
        .first;
    await tester.ensureVisible(packAction);
    await tester.pumpAndSettle();
    await tester.tap(packAction);
    final previewDeadline = DateTime.now().add(const Duration(seconds: 60));
    while (find.byType(PackInstallDialog).evaluate().isEmpty &&
        DateTime.now().isBefore(previewDeadline)) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();
    expect(find.byType(PackInstallDialog), findsOneWidget);
    await screenshot('community-pack-preview');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await temporary.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
