import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'multiplayer_invitation.dart';

enum MultiplayerState {
  idle('尚未联机'),
  starting('正在启动网络助手'),
  gathering('正在获取连接地址'),
  waitingAnswer('等待回应信息'),
  connecting('正在尝试直连'),
  securing('正在验证对端身份'),
  configuring('正在建立游戏通道'),
  connected('已建立直连'),
  reconnecting('连接暂时中断，正在重试'),
  stopping('正在断开联机'),
  failed('联机失败');

  final String label;
  const MultiplayerState(this.label);
}

String multiplayerHelperPath() {
  final root = p.dirname(Platform.resolvedExecutable);
  return Platform.isMacOS
      ? p.normalize(
          p.join(root, '..', 'Resources', 'fyl-network', 'fyl-network'),
        )
      : p.join(
          root,
          'data',
          'fyl-network',
          Platform.isWindows ? 'fyl-network.exe' : 'fyl-network',
        );
}

String multiplayerError(String code) => switch (code) {
  'ticket_expired' => '联机信息已过期，请重新创建',
  'ticket_invalid' || 'ticket_large' || 'protocol_error' => '联机信息格式无效',
  'wrong_room' => '回应信息不属于当前房间',
  'no_candidates' || 'gather_timeout' => '无法获取连接地址，请检查网络',
  'direct_failed' => '无法建立直连，当前网络可能不支持穿透',
  'peer_identity' => '对端身份校验失败，请重新交换联机信息',
  'local_port_failed' => '无法创建本机游戏连接端口',
  'game_not_found' => '所选端口未检测到 Minecraft 游戏，请确认已对局域网开放',
  'connection_lost' => '联机连接已断开',
  'helper_missing' => '缺少联机组件，请安装包含联机组件的完整构建',
  'helper_closed' => '网络助手已退出',
  _ => '联机失败，请检查网络后重试',
};

typedef MultiplayerHelperLauncher =
    Future<Process?> Function(String executable, List<String> arguments);

/// Invitations and IPC credentials live only in memory, never launcher.json,
/// account storage, logs or temporary files.
class MultiplayerController extends ChangeNotifier {
  final String Function() helperPath;
  final MultiplayerHelperLauncher launch;
  MultiplayerController({
    String Function()? helperPath,
    MultiplayerHelperLauncher? launch,
  }) : helperPath = helperPath ?? multiplayerHelperPath,
       launch = launch ?? launchMultiplayerHelper;

  MultiplayerState state = MultiplayerState.idle;
  bool isHost = true;
  String? ticket, room, error, gameName, _gameAddress;
  DateTime? expires;
  int gamePort = 0, sent = 0, received = 0;
  ServerSocket? _server;
  Socket? _socket;
  Process? _process;
  Completer<void>? _ready, _stopped;
  Future<void>? _stopping;
  int _generation = 0;
  bool _disposed = false, _starting = false;
  bool get active =>
      _starting ||
      _socket != null ||
      _process != null ||
      state == MultiplayerState.stopping;
  bool get connected =>
      state == MultiplayerState.connected ||
      state == MultiplayerState.reconnecting;
  String? get gameAddress =>
      isHost ? (gamePort > 0 ? '127.0.0.1:$gamePort' : null) : _gameAddress;
  bool get supported =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> host() => _begin(true, null);
  Future<void> join(String invitation) async {
    final parsed = MultiplayerInvitation.parse(invitation, kind: 'offer');
    await _begin(false, parsed.text);
  }

  Future<void> _begin(bool owner, String? invitation) async {
    if (_disposed || active || _stopping != null) throw StateError('请先断开当前联机');
    final executable = p.normalize(p.absolute(helperPath()));
    if (!await File(executable).exists()) {
      error = multiplayerError('helper_missing');
      state = MultiplayerState.failed;
      _notify();
      return;
    }
    if (_disposed || active || _stopping != null) throw StateError('请先断开当前联机');
    final generation = ++_generation;
    _starting = true;
    isHost = owner;
    error = null;
    ticket = null;
    expires = null;
    room = gameName = _gameAddress = null;
    gamePort = sent = received = 0;
    state = MultiplayerState.starting;
    _ready = Completer<void>();
    unawaited(_ready!.future.catchError((Object _) {}));
    _stopped = Completer<void>();
    _notify();
    final random = Random.secure();
    final token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      if (generation != _generation ||
          _disposed ||
          state == MultiplayerState.stopping) {
        await server.close();
        return;
      }
      _server = server;
      _server!.listen((socket) => _accept(socket, token, generation));
      final ready = _ready!.future;
      // Install the error handler before the child can report startup failure.
      final awaiting = ready.timeout(const Duration(seconds: 120));
      unawaited(awaiting.catchError((Object _) {}));
      final process = await launch(executable, [
        '--control-port',
        '${_server!.port}',
        '--control-token',
        token,
      ]);
      if (generation != _generation ||
          _disposed ||
          state == MultiplayerState.stopping) {
        process?.kill();
        return;
      }
      _process = process;
      if (process != null) {
        unawaited(
          process.exitCode.then((_) {
            if (generation == _generation && !(_ready?.isCompleted ?? true)) {
              _ready!.completeError(StateError('helper_closed'));
            }
          }),
        );
      }
      await awaiting;
      if (generation != _generation || _disposed) return;
      _starting = false;
      _send({'type': owner ? 'host' : 'join', 'ticket': ?invitation});
    } catch (e) {
      if (generation != _generation ||
          _disposed ||
          state == MultiplayerState.stopping) {
        return;
      }
      final message = multiplayerError('helper_closed');
      await stop();
      error = message;
      state = MultiplayerState.failed;
      _notify();
    }
  }

  void _accept(Socket socket, String token, int generation) {
    if (generation != _generation ||
        _socket != null ||
        state == MultiplayerState.stopping) {
      socket.destroy();
      return;
    }
    final buffer = <int>[];
    bool authenticated = false;
    final timer = Timer(const Duration(seconds: 8), () {
      if (!authenticated) socket.destroy();
    });
    socket.listen(
      (bytes) {
        if (generation != _generation ||
            (_disposed && state != MultiplayerState.stopping)) {
          socket.destroy();
          return;
        }
        buffer.addAll(bytes);
        if (buffer.length > 131072) {
          socket.destroy();
          return;
        }
        int end;
        while ((end = buffer.indexOf(10)) >= 0) {
          final line = buffer.sublist(0, end);
          buffer.removeRange(0, end + 1);
          try {
            final message =
                jsonDecode(utf8.decode(line)) as Map<String, dynamic>;
            if (!authenticated) {
              if (message['type'] != 'hello' ||
                  message['version'] != 1 ||
                  message['token'] != token ||
                  state == MultiplayerState.stopping ||
                  _socket != null) {
                socket.destroy();
                return;
              }
              authenticated = true;
              timer.cancel();
              _socket = socket;
              unawaited(_server?.close());
              _server = null;
              _send({'type': 'auth', 'token': token});
            } else {
              _event(message);
            }
          } catch (_) {
            socket.destroy();
            return;
          }
        }
      },
      onError: (Object _) {
        socket.destroy();
      },
      onDone: () {
        timer.cancel();
        if (!authenticated || generation != _generation) return;
        _socket = null;
        if (!(_ready?.isCompleted ?? true)) {
          _ready!.completeError(StateError('helper_closed'));
        }
        if (!(_stopped?.isCompleted ?? true)) _stopped!.complete();
        if (state != MultiplayerState.stopping &&
            state != MultiplayerState.failed) {
          error = multiplayerError('helper_closed');
          state = MultiplayerState.failed;
          _notify();
        }
      },
    );
  }

  void _event(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'ready':
        if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      case 'state':
        state = switch (e['state']) {
          'gathering' => MultiplayerState.gathering,
          'waiting_answer' => MultiplayerState.waitingAnswer,
          'connecting' => MultiplayerState.connecting,
          'securing' => MultiplayerState.securing,
          'configuring' => MultiplayerState.configuring,
          'connected' => MultiplayerState.connected,
          'reconnecting' => MultiplayerState.reconnecting,
          _ => state,
        };
      case 'ticket':
        ticket = e['text'] as String;
        expires = DateTime.fromMillisecondsSinceEpoch(
          (e['expires'] as int) * 1000,
        );
        room = e['room'] as String;
      case 'stats':
        sent = e['sent'] as int;
        received = e['received'] as int;
      case 'game':
        gamePort = e['port'] as int;
        gameName = e['name'] as String;
        if (gamePort > 0) error = null;
        final address = e['address'] as String?;
        if (address != null) _gameAddress = address.isEmpty ? null : address;
      case 'input_error':
        error = multiplayerError(e['code'] as String? ?? '');
      case 'error':
        error = multiplayerError(e['code'] as String? ?? '');
        state = MultiplayerState.failed;
        ticket = null;
      case 'stopped':
        if (!(_stopped?.isCompleted ?? true)) _stopped!.complete();
    }
    _notify();
  }

  void answer(String value) {
    if (!isHost || state != MultiplayerState.waitingAnswer) {
      throw StateError('当前房间不在等待回应');
    }
    final parsed = MultiplayerInvitation.parse(value, kind: 'answer');
    error = null;
    _send({'type': 'answer', 'ticket': parsed.text});
    _notify();
  }

  void sharePort(int port) {
    if (!isHost || !connected || port < 0 || port > 65535) {
      throw ArgumentError('游戏端口无效');
    }
    _send({'type': 'share', 'port': port});
  }

  void _send(Map<String, dynamic> command) {
    if (_socket == null) throw StateError('网络助手已退出');
    _socket!.write('${jsonEncode(command)}\n');
  }

  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);
  Future<void> _stop() async {
    _starting = false;
    final socket = _socket;
    _socket = null;
    final stopped = _stopped;
    final server = _server;
    _server = null;
    state = MultiplayerState.stopping;
    _notify();
    if (!(_ready?.isCompleted ?? true)) {
      _ready!.completeError(StateError('helper_closed'));
    }
    try {
      if (socket != null) {
        socket.write('${jsonEncode({'type': 'stop'})}\n');
        await socket.flush();
        // Helper acknowledges after closing its game forwarding session.
        if (stopped != null) {
          await stopped.future.timeout(const Duration(seconds: 30));
        }
      }
    } catch (_) {
      /* Closing IPC also makes the helper tear down the network. */
    } finally {
      socket?.destroy();
      await server?.close();
      final process = _process;
      _process = null;
      if (process != null) {
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } catch (_) {
          process.kill();
        }
      }
    }
    ticket = room = gameName = error = _gameAddress = null;
    expires = null;
    gamePort = sent = received = 0;
    state = MultiplayerState.idle;
    ++_generation;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

Future<Process> launchMultiplayerHelper(
  String executable,
  List<String> arguments,
) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: p.dirname(executable),
  );
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  return process;
}
