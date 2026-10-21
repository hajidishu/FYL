import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:forui/forui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/controller.dart';
import 'core/models.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final controller = LauncherController(
    supportDirectory: support.path,
    platform: await HostPlatform.detect(),
  );
  await controller.initialize();
  runApp(LauncherApp(controller: controller));
  unawaited(
    windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1180, 780),
        minimumSize: Size(780, 560),
        center: true,
        backgroundColor: Color(0xFF101215),
        title: 'free_your_launcher',
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    ),
  );
  unawaited(controller.refreshVersions());
}

class LauncherApp extends StatelessWidget {
  final LauncherController controller;
  final bool nativeWindow;
  const LauncherApp({
    required this.controller,
    this.nativeWindow = true,
    super.key,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      return MaterialApp(
        title: 'free_your_launcher',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: const LauncherColors(false).material,
        darkTheme: const LauncherColors(true).material,
        themeMode: switch (controller.settings.theme) {
          'light' => ThemeMode.light,
          'system' => ThemeMode.system,
          _ => ThemeMode.dark,
        },
        builder: (context, child) =>
            FTheme(data: LauncherColors.of(context).forui, child: child!),
        home: LauncherShell(controller: controller, nativeWindow: nativeWindow),
      );
    },
  );
}
