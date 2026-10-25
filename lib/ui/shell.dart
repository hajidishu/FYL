import '../l10n/app_localizations.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:window_manager/window_manager.dart';

import '../core/controller.dart';
import '../core/build_info.dart';
import 'pages.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'game_failure_dialog.dart';
import 'file_drop.dart';
import 'launcher_background.dart';
import 'multiplayer_page.dart';

class LauncherShell extends StatefulWidget {
  final LauncherController controller;
  final bool nativeWindow;
  const LauncherShell({
    required this.controller,
    required this.nativeWindow,
    super.key,
  });
  @override
  State<LauncherShell> createState() => _LauncherShellState();
}

class _LauncherShellState extends State<LauncherShell> with WindowListener {
  int page = 0;
  bool settingsDirty = false;
  bool instanceDirty = false;
  bool closing = false;
  bool showingFailure = false;
  bool failureScheduled = false;
  String? dismissedUpdate;
  final settingsKey = GlobalKey<SettingsPageState>();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scheduleFailure);
    _scheduleFailure();
    if (widget.nativeWindow) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
      unawaited(widget.controller.launcherUpdater.check(automatic: true));
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scheduleFailure);
    if (widget.nativeWindow) windowManager.removeListener(this);
    super.dispose();
  }

  void _scheduleFailure() {
    if (!mounted ||
        closing ||
        showingFailure ||
        failureScheduled ||
        widget.controller.gameFailures.isEmpty) {
      return;
    }
    failureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      failureScheduled = false;
      if (mounted &&
          !closing &&
          !showingFailure &&
          widget.controller.gameFailures.isNotEmpty) {
        unawaited(_showFailure());
      }
    });
  }

  Future<void> _showFailure() async {
    showingFailure = true;
    final failure = widget.controller.gameFailures.first;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => GameFailureDialog(failure: failure),
      );
      if (mounted) await widget.controller.dismissGameFailure(failure);
    } catch (error) {
      widget.controller.errorMessage = '处理错误报告失败：$error';
      widget.controller.notifyListeners();
    } finally {
      showingFailure = false;
      if (mounted) _scheduleFailure();
    }
  }

  Future<bool> _confirm(String title, String message, String button) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: LText(title, style: const TextStyle(fontSize: 18)),
          content: LText(message),
          actions: [
            AppButton(
              '返回',
              secondary: true,
              onPressed: () => Navigator.pop(context, false),
            ),
            AppButton(button, onPressed: () => Navigator.pop(context, true)),
          ],
        ),
      ) ??
      false;

  Future<void> navigate(int value) async {
    if (value == page) return;
    if (page == 3 && settingsDirty || page == 1 && instanceDirty) {
      final discard = await _confirm('有尚未保存的设置', '离开后会放弃本次修改。', '放弃修改');
      if (!discard || !mounted) return;
    }
    setState(() {
      page = value;
      settingsDirty = false;
      instanceDirty = false;
    });
  }

  @override
  void onWindowClose() async {
    if (closing) return;
    closing = true;
    try {
      if ((settingsDirty || instanceDirty) &&
          !await _confirm('有尚未保存的设置', '关闭启动器会放弃本次设置修改。', '关闭启动器')) {
        return;
      }
      if (widget.controller.installing) {
        if (!mounted ||
            !await _confirm('任务正在进行', '关闭前会停止可取消的任务，并等待文件操作结束。', '停止任务并关闭')) {
          return;
        }
        await widget.controller.stopActiveTasks();
      }
      await widget.controller.flush();
      await widget.controller.multiplayer.stop();
      await windowManager.destroy();
    } catch (e) {
      widget.controller.errorMessage = '关闭启动器失败：$e';
      widget.controller.notifyListeners();
    } finally {
      closing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final controller = widget.controller;
    final content = Scaffold(
      body: FScaffold(
        childPad: false,
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: widget.nativeWindow
                          ? (_) => windowManager.startDragging()
                          : null,
                      onDoubleTap: widget.nativeWindow
                          ? () async {
                              if (await windowManager.isMaximized()) {
                                await windowManager.unmaximize();
                              } else {
                                await windowManager.maximize();
                              }
                            }
                          : null,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: Row(
                          children: [
                            Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: c.accentBackground,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                FIcons.box,
                                color: c.accent,
                                size: 19,
                              ),
                            ),
                            const SizedBox(width: 11),
                            Text(
                              'FYL',
                              style: TextStyle(
                                color: c.foreground,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (widget.nativeWindow) ...[
                    _windowButton(
                      FIcons.minus,
                      '最小化',
                      () => windowManager.minimize(),
                    ),
                    _windowButton(FIcons.square, '最大化 / 还原', () async {
                      if (await windowManager.isMaximized()) {
                        await windowManager.unmaximize();
                      } else {
                        await windowManager.maximize();
                      }
                    }),
                    _windowButton(FIcons.x, '关闭', () => windowManager.close()),
                  ],
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 950;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: compact ? 76 : 216,
                        decoration: BoxDecoration(
                          color: c.sidebar,
                          border: Border(
                            right: BorderSide(
                              color: c.border.withValues(alpha: .5),
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: compact ? 10 : 14,
                            vertical: 20,
                          ),
                          child: Column(
                            children: [
                              if (!compact)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 12,
                                    bottom: 15,
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: LText(
                                      '导航',
                                      style: TextStyle(
                                        color: c.muted,
                                        fontSize: 10,
                                        letterSpacing: 1.6,
                                      ),
                                    ),
                                  ),
                                ),
                              _navigation(0, '开始游戏', FIcons.gamepad2, compact),
                              const SizedBox(height: 7),
                              _navigation(1, '版本管理', FIcons.layers, compact),
                              const SizedBox(height: 7),
                              _navigation(2, '下载管理', FIcons.download, compact),
                              const SizedBox(height: 7),
                              _navigation(4, '联机', FIcons.network, compact),
                              const SizedBox(height: 7),
                              _navigation(3, '设置', FIcons.settings, compact),
                              const Spacer(),
                              LText(
                                launcherVersion == 'development'
                                    ? '开发版'
                                    : 'v$launcherVersion',
                                style: TextStyle(
                                  color: c.muted.withValues(alpha: .65),
                                  fontSize: 9,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: LauncherBackground(
                          path: controller.settings.backgroundPath,
                          opacity: controller.settings.backgroundOpacity ?? .35,
                          child: Column(
                            children: [
                              if (controller.errorMessage != null ||
                                  controller.notice != null)
                                _message(),
                              if (controller.launcherUpdater.available !=
                                      null &&
                                  dismissedUpdate !=
                                      controller
                                          .launcherUpdater
                                          .available!
                                          .version)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    28,
                                    12,
                                    28,
                                    0,
                                  ),
                                  child: Surface(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: LText(
                                            '发现新版本 ${controller.launcherUpdater.available!.version}',
                                          ),
                                        ),
                                        AppButton(
                                          '查看更新',
                                          small: true,
                                          onPressed: () => navigate(3),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          icon: const Icon(FIcons.x, size: 16),
                                          tooltip: tr('关闭'),
                                          onPressed: () => setState(
                                            () => dismissedUpdate = controller
                                                .launcherUpdater
                                                .available!
                                                .version,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: switch (page) {
                                  0 => HomePage(
                                    controller: controller,
                                    navigate: navigate,
                                    nativeWindow: widget.nativeWindow,
                                  ),
                                  1 => InstancesPage(
                                    controller: controller,
                                    navigate: navigate,
                                    onDirty: (value) => instanceDirty = value,
                                  ),
                                  2 => DownloadsPage(
                                    controller: controller,
                                    navigate: navigate,
                                  ),
                                  4 => MultiplayerPage(
                                    controller: controller.multiplayer,
                                  ),
                                  _ => SettingsPage(
                                    key: settingsKey,
                                    controller: controller,
                                    onDirty: (value) {
                                      settingsDirty = value;
                                    },
                                  ),
                                },
                              ),
                              Container(
                                height: 32,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 28,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    top: BorderSide(
                                      color: c.border.withValues(alpha: .5),
                                    ),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 5,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: c.accent,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: LText(
                                        controller.activityText,
                                        style: TextStyle(
                                          color: c.muted,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      'FYL · ${controller.platform.os} / ${controller.platform.arch}',
                                      style: TextStyle(
                                        color: c.muted,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    return FileDropRegion(
      controller: controller,
      enabled: !closing && !showingFailure,
      onTaskStarted: () => unawaited(navigate(2)),
      child: content,
    );
  }

  Widget _windowButton(IconData icon, String tooltip, VoidCallback onPressed) =>
      IconButton(
        onPressed: onPressed,
        tooltip: AppLocalizations.of(context).textOrNull(tooltip),
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, size: 13, color: LauncherColors.of(context).muted),
      );

  Widget _navigation(int index, String label, IconData icon, bool compact) {
    final c = LauncherColors.of(context);
    final selected = page == index;
    final child = Container(
      height: 44,
      padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 14),
      decoration: BoxDecoration(
        color: selected ? c.accentBackground : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: compact
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: selected ? c.accent : c.muted),
          if (!compact) ...[
            const SizedBox(width: 12),
            Flexible(
              child: LText(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? c.accent : c.muted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (index == 2 && widget.controller.installing) ...[
              const Spacer(),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ],
        ],
      ),
    );
    return Semantics(
      key: ValueKey('navigation-$index'),
      selected: selected,
      label: AppLocalizations.of(context).text(label),
      button: true,
      excludeSemantics: true,
      onTap: () => navigate(index),
      child: LTooltip(
        message: compact ? label : '',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => navigate(index),
          child: child,
        ),
      ),
    );
  }

  Widget _message() {
    final controller = widget.controller;
    final c = LauncherColors.of(context);
    final error = controller.errorMessage != null;
    return Container(
      margin: const EdgeInsets.fromLTRB(28, 12, 28, 0),
      padding: const EdgeInsets.fromLTRB(13, 9, 5, 9),
      decoration: BoxDecoration(
        color: error
            ? const Color(0xFF612C29).withValues(alpha: .25)
            : c.accentBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            error ? FIcons.circleAlert : FIcons.circleCheck,
            size: 16,
            color: error ? const Color(0xFFEF9990) : c.accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: LText(
              controller.errorMessage ?? controller.notice!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: error ? const Color(0xFFEF9990) : c.accent,
              ),
            ),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context).textOrNull('关闭提示'),
            onPressed: controller.dismissMessage,
            icon: Icon(FIcons.x, size: 14, color: c.muted),
          ),
        ],
      ),
    );
  }
}
