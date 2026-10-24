import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:forui/forui.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../core/account_store.dart';
import '../core/controller.dart';
import '../core/data_directory.dart';
import '../core/models.dart';
import '../core/launcher_update_install.dart';
import '../main.dart' show LauncherApp;
import 'byte_size.dart';
import 'theme.dart';

class LauncherRuntime extends StatefulWidget {
  final DataDirectoryManager directories;
  final HostPlatform platform;
  final bool nativeWindow;
  final void Function(LauncherController)? onReady;
  final VoidCallback? onStartupReady;
  const LauncherRuntime({
    required this.directories,
    required this.platform,
    this.nativeWindow = true,
    this.onReady,
    this.onStartupReady,
    super.key,
  });
  @override
  State<LauncherRuntime> createState() => _LauncherRuntimeState();
}

class _LauncherRuntimeState extends State<LauncherRuntime> with WindowListener {
  LauncherController? controller;
  DataDirectoryLease? lease;
  final path = TextEditingController();
  String? error;
  bool busy = true;
  bool startupReady = false;
  DataMigrationProgress? progress;
  String language = 'zh-Hans';
  String? chosenLanguage;

  void presentStartup() {
    if (startupReady) return;
    startupReady = true;
    widget.onStartupReady?.call();
  }

  Future<void> readLanguage(String directory) async {
    for (final name in ['launcher.json', 'launcher.json.bak']) {
      try {
        final saved =
            jsonDecode(await File(p.join(directory, name)).readAsString())
                as Json;
        final value = (saved['settings'] as Map?)?['language'];
        if (value is String &&
            launcherLanguages.containsKey(value) &&
            mounted) {
          setState(() => language = value);
        }
        return;
      } catch (_) {
        /* The controller handles configuration recovery. */
      }
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.nativeWindow) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    unawaited(start());
  }

  Future<void> start() async {
    try {
      final location = await widget.directories.read();
      path.text = location.directory;
      await readLanguage(location.directory);
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '无法打开数据目录：$e';
          busy = false;
        });
        presentStartup();
      }
    }
  }

  Future<void> load() async {
    final location = await widget.directories.read();
    final target = await widget.directories.activate(
      onProgress: (value) {
        if (mounted) {
          setState(() => progress = value);
          presentStartup();
        }
      },
    );
    DataDirectoryLease? nextLease;
    LauncherController? next;
    try {
      nextLease = await DataDirectoryLease.acquire(target);
      // Windows credentials are copied as DPAPI ciphertext. macOS/Linux keep
      // secrets in the OS vault, with a profile ID that travels with the data.
      if (!Platform.isWindows &&
          location.migrateFrom != null &&
          !await File(
            p.join(location.migrateFrom!, 'credentials', 'profile-id'),
          ).exists()) {
        final json =
            jsonDecode(
                  await File(p.join(target, 'launcher.json')).readAsString(),
                )
                as Json;
        final old = SecureAccountTokenStore(
          supportDirectory: location.migrateFrom,
          legacyNamespace: true,
        );
        final destination = SecureAccountTokenStore(supportDirectory: target);
        final ids = [
          for (final account in json['accounts'] as List<dynamic>? ?? [])
            if (account is Map && account['kind'] == 'microsoft')
              account['id'] as String,
          if (json['hasCurseforgeApiKey'] == true)
            'settings.curseforge-api-key',
        ];
        for (final id in ids) {
          final value = await old.readValue(id);
          if (value != null) await destination.writeValue(id, value);
        }
      }
      final legacy = widget.directories.legacyDirectory();
      // Staying in the original macOS/Linux directory also keeps its original
      // OS-vault namespace. Windows continues reading the same DPAPI files.
      final legacyStore =
          !Platform.isWindows &&
              legacy != null &&
              p.equals(p.normalize(p.absolute(legacy)), target) &&
              !await File(p.join(target, 'credentials', 'profile-id')).exists()
          ? SecureAccountTokenStore(
              supportDirectory: target,
              legacyNamespace: true,
            )
          : null;
      next = LauncherController(
        supportDirectory: target,
        platform: widget.platform,
        dataDirectories: widget.directories,
        onDataDirectoryChange: changeDirectory,
        tokenStore: legacyStore,
        appSecrets: legacyStore,
      );
      await next.initialize();
      if (next.errorMessage != null) {
        throw StateError(next.errorMessage!);
      }
      if (chosenLanguage != null) {
        await next.saveSettings(
          next.settings.copy()..language = chosenLanguage!,
        );
      }
      final warning = await widget.directories.completeMigration();
      if (warning != null) next.notice = warning;
      if (widget.nativeWindow) await confirmLauncherUpdateStartup(target);
      if (!mounted) {
        next.dispose();
        await nextLease.close();
        return;
      }
      final active = next;
      setState(() {
        controller = active;
        lease = nextLease;
        busy = false;
        progress = null;
        error = null;
        chosenLanguage = null;
        language = active.settings.language;
      });
      presentStartup();
      if (widget.onReady != null) {
        widget.onReady!(active);
      } else {
        unawaited(active.refreshVersions());
      }
    } catch (_) {
      next?.dispose();
      await nextLease?.close();
      rethrow;
    }
  }

  Future<void> changeDirectory(String directory, bool migrateData) async {
    final previous = controller!;
    language = previous.settings.language;
    // Validate and persist the recovery plan before touching either directory.
    await widget.directories.select(
      directory,
      source: previous.supportDirectory,
      migrate: migrateData,
    );
    setState(() {
      controller = null;
      busy = true;
      error = null;
      progress = null;
      path.text = directory;
    });
    await WidgetsBinding.instance.endOfFrame;
    previous.dispose();
    await lease?.close();
    lease = null;
    try {
      await load();
    } catch (e) {
      try {
        await widget.directories.restore(previous.supportDirectory);
        await load();
        controller?.errorMessage = '数据目录切换失败，已恢复原目录：$e';
        controller?.notifyListeners();
      } catch (recovery) {
        if (mounted) {
          setState(() {
            error = '数据已保留，恢复目录失败：$recovery\n原目录：${previous.supportDirectory}';
            busy = false;
          });
        }
      }
    }
  }

  Future<void> choose() async {
    setState(() {
      busy = true;
      error = null;
      progress = null;
    });
    try {
      if (widget.directories.directoryOverride == null) {
        await widget.directories.select(path.text.trim());
      }
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '无法使用此数据目录：$e';
          busy = false;
        });
      }
    }
  }

  @override
  void onWindowClose() {
    if (controller != null || !widget.nativeWindow) return;
    if (!busy) unawaited(windowManager.destroy());
  }

  @override
  void dispose() {
    if (widget.nativeWindow) windowManager.removeListener(this);
    controller?.dispose();
    unawaited(lease?.close());
    path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = controller;
    if (active != null) {
      return LauncherApp(
        key: ObjectKey(active),
        controller: active,
        nativeWindow: widget.nativeWindow,
      );
    }
    if (!startupReady && busy && progress == null) {
      return const SizedBox.shrink();
    }
    const colors = LauncherColors(true);
    AppLocalizations.current = AppLocalizations.forLanguage(language);
    return MaterialApp(
      theme: colors.material,
      locale: launcherLocale(language),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        FLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => FTheme(data: colors.forui, child: child!),
      home: Scaffold(
        body: Column(
          children: [
            GestureDetector(
              onPanStart: widget.nativeWindow
                  ? (_) => windowManager.startDragging()
                  : null,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'FYL',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      tooltip: trNullable('关闭'),
                      onPressed: busy || !widget.nativeWindow
                          ? null
                          : () => windowManager.destroy(),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Surface(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LText(
                            busy
                                ? progress == null
                                      ? '正在打开数据目录'
                                      : '正在迁移数据'
                                : '选择数据目录',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 18),
                          if (busy) ...[
                            LinearProgressIndicator(
                              value:
                                  progress == null || progress!.totalBytes == 0
                                  ? null
                                  : (progress!.bytes / progress!.totalBytes)
                                        .clamp(0.0, 1.0),
                            ),
                            const SizedBox(height: 12),
                            LText(
                              progress == null
                                  ? path.text
                                  : '${progress!.files}/${progress!.totalFiles} 个文件 · ${formatByteSize(progress!.bytes)} / ${formatByteSize(progress!.totalBytes)}',
                            ),
                          ] else ...[
                            SelectBox<String>(
                              value: language,
                              items: launcherLanguages,
                              localizeItems: false,
                              onChanged: (value) => setState(() {
                                language = value;
                                chosenLanguage = value;
                              }),
                            ),
                            const SizedBox(height: 14),
                            AppInput(
                              controller: path,
                              label: '启动器数据目录',
                              enabled:
                                  widget.directories.directoryOverride == null,
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              children: [
                                AppButton(
                                  '选择文件夹',
                                  secondary: true,
                                  onPressed:
                                      widget.directories.directoryOverride !=
                                          null
                                      ? null
                                      : () async {
                                          final value = await getDirectoryPath(
                                            confirmButtonText: tr('选择数据目录'),
                                          );
                                          if (value != null && mounted) {
                                            setState(() => path.text = value);
                                          }
                                        },
                                ),
                                AppButton(
                                  '恢复默认目录',
                                  secondary: true,
                                  onPressed:
                                      widget.directories.directoryOverride !=
                                          null
                                      ? null
                                      : () => setState(
                                          () => path.text = widget
                                              .directories
                                              .defaultDirectory,
                                        ),
                                ),
                              ],
                            ),
                            if (error != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: LSelectableText(
                                  error!,
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ),
                            if (widget.directories.directoryOverride != null)
                              const LText(
                                '请修改 --data-dir 或 FYL_DATA_DIR 后重试。',
                                style: TextStyle(fontSize: 12),
                              ),
                            const SizedBox(height: 12),
                            AppButton('继续', onPressed: choose),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
