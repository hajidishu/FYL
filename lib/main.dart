import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:forui/forui.dart';
import 'package:window_manager/window_manager.dart';

import 'core/controller.dart';
import 'core/models.dart';
import 'core/data_directory.dart';
import 'core/launcher_update_install.dart';
import 'ui/launcher_runtime.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'l10n/app_localizations.dart';

Future<void> main(List<String> arguments) async {
  await handleLauncherUpdateMode(arguments);
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  String? dataDirectory = Platform.environment['FYL_DATA_DIR'];
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i].startsWith('--data-dir=')) {
      dataDirectory = arguments[i].substring('--data-dir='.length);
    } else if (arguments[i] == '--data-dir') {
      if (++i == arguments.length) {
        throw const FormatException('--data-dir 需要指定目录。');
      }
      dataDirectory = arguments[i];
    }
  }
  runApp(
    LauncherRuntime(
      directories: DataDirectoryManager(
        startupDirectory: Platform.environment['FYL_RESTART_DATA_DIR'],
        directoryOverride: dataDirectory?.trim().isEmpty == true
            ? null
            : dataDirectory,
      ),
      platform: await HostPlatform.detect(),
    ),
  );
  unawaited(
    windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1180, 780),
        minimumSize: Size(780, 560),
        center: true,
        backgroundColor: Color(0xFF101215),
        title: 'FYL',
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    ),
  );
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
      AppLocalizations.current = AppLocalizations.forLanguage(
        controller.settings.language,
      );
      return MaterialApp(
        title: 'FYL',
        debugShowCheckedModeBanner: false,
        locale: launcherLocale(controller.settings.language),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: LauncherColors(
          false,
          accentColor: controller.settings.accentColor,
        ).material,
        darkTheme: LauncherColors(
          true,
          accentColor: controller.settings.accentColor,
        ).material,
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
