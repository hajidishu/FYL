import 'dart:async';

import 'package:flutter/services.dart';

import 'game_process_priority.dart';

/// Keeps a native process handle until the game window opens (or launch ends).
/// Native handles identify this launch even if its wrapper exits early.
class GameProcessPrioritySession {
  static const _channel = MethodChannel('fyl/game_process_priority');
  static int _sequence = 0;
  final int pid;
  final GameProcessPriority priority;
  final void Function(String) onLog;
  final String _id;
  Future<void>? _start, _finish;
  bool _available = false;

  GameProcessPrioritySession({
    required this.pid,
    required this.priority,
    required this.onLog,
  }) : _id = '$pid-${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';

  Future<void> start() => _start ??= _begin();

  Future<void> _begin() async {
    try {
      // A late reply must still be followed by finish, which releases the handle.
      _available = true;
      final result = await _channel
          .invokeMapMethod<String, dynamic>('begin', {
            'id': _id,
            'pid': pid,
            'priority': priority.name,
          })
          .timeout(const Duration(seconds: 2));
      _report(result);
    } on MissingPluginException {
      _available = false;
      onLog('[Launcher] 无法设置游戏进程优先级：原生接口不可用。');
    } catch (error) {
      onLog('[Launcher] 无法设置游戏进程优先级：$error');
    }
  }

  // Both process exit and window discovery can finish the same launch.
  Future<void> finish() => _finish ??= _end();

  Future<void> _end() async {
    await start();
    if (!_available) return;
    try {
      _report(
        await _channel
            .invokeMapMethod<String, dynamic>('finish', {'id': _id})
            .timeout(const Duration(seconds: 2)),
      );
    } catch (error) {
      onLog('[Launcher] 无法确认游戏进程优先级：$error');
    } finally {
      _available = false;
    }
  }

  void _report(Map<String, dynamic>? result) {
    if (result == null) return;
    for (final process in result['processes'] as List? ?? const []) {
      final actual = GameProcessPriority.fromName(process['actual']);
      final detail = process['success'] == true
          ? ''
          : ' · Windows 错误 ${process['error']}';
      onLog(
        '[Launcher] 游戏进程优先级：PID ${process['pid']} · '
        '请求 ${priority.label} · 实际 ${actual?.label ?? '未知'}$detail',
      );
    }
    if (result['discoveryError'] case final int error) {
      onLog('[Launcher] 无法读取游戏子进程：Windows 错误 $error');
    }
  }
}
