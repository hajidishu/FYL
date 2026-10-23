import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

typedef GameWindowProbe = Future<bool?> Function(int pid);

Future<bool?> probeGameWindow(int pid) async {
  try {
    return await const MethodChannel('fyl/game_window')
        .invokeMethod<bool>('isVisible', {'pid': pid})
        .timeout(const Duration(seconds: 2));
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  } on TimeoutException {
    return null;
  }
}

/// Watches only this launch's process. A new JVM alone does not mean a window exists.
class GameWindowWaiter {
  final GameWindowProbe probe;
  final Duration interval;
  final _ready = Completer<bool>();
  Timer? _timer;
  bool _probing = false, _unsupported = false, _rendered = false;
  GameWindowWaiter({
    this.probe = probeGameWindow,
    this.interval = const Duration(milliseconds: 500),
  });

  // On desktops that cannot enumerate other apps' windows (e.g. native Wayland),
  // rendering/atlas messages provide evidence after the game has created a context.
  static bool indicatesRendering(String message) => RegExp(
    r'(?:OpenGL (?:renderer|version)(?: string)?\s*:|'
    r'Created:\s*\d+x\d+(?:x\d+)?\s+(?:minecraft:)?textures/atlas/)',
    caseSensitive: false,
  ).hasMatch(message);

  void observe(String message) {
    if (_ready.isCompleted) return;
    _rendered |= indicatesRendering(message);
    if (_unsupported && _rendered) _finish(true);
  }

  Future<bool> wait(Process process) {
    int? pid;
    try {
      pid = process.pid;
    } catch (_) {
      _unsupported = true;
    }
    unawaited(
      process.exitCode.then<void>(
        (_) => _finish(false),
        onError: (Object _, StackTrace _) => _finish(false),
      ),
    );
    if (pid != null && pid > 0) {
      final processId = pid;
      Future<void> check() async {
        if (_probing || _ready.isCompleted) return;
        _probing = true;
        bool? visible;
        try {
          visible = await probe(processId);
        } catch (_) {
          /* Retry/fallback. */
        }
        _probing = false;
        if (_ready.isCompleted) return;
        if (visible == true) {
          _finish(true);
        } else if (visible == null) {
          _unsupported = true;
          if (_rendered) _finish(true);
        }
      }

      _timer = Timer.periodic(interval, (_) => unawaited(check()));
      unawaited(check());
    } else if (_rendered) {
      _finish(true);
    }
    return _ready.future;
  }

  void stop() => _finish(false);
  void _finish(bool ready) {
    _timer?.cancel();
    if (!_ready.isCompleted) _ready.complete(ready);
  }
}
