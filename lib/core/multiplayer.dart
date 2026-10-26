import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'multiplayer_invitation.dart';
import 'build_info.dart';
import 'multiplayer_settings.dart';
import 'minecraft.dart' show writeJson;

enum MultiplayerState {
  idle('尚未联机'),
  starting('正在启动网络助手'),
  gathering('正在获取连接地址'),
  waitingAnswer('等待回应信息'),
  hosting('房间已创建'),
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
  'helper_version' => '联机组件版本过旧，请重新构建或更新完整启动器',
  'invitation_paused' => '当前邀请已停止接纳新人，请重新生成邀请',
  'answer_used' => '这份回应已经导入，请勿重复添加',
  'peer_limit' => '房间连接数量已达上限，请移除不再使用的连接',
  'room_busy' => '房间正在处理操作，请稍后重试',
  'invalid_settings' => '联机设置无效，请检查协议、端口和超时范围',
  'port_unavailable' => '本地 UDP 端口不可用，请更换端口或使用自动分配',
  _ => '联机失败，请检查网络后重试',
};

MultiplayerState _connectionState(String? value, MultiplayerState fallback) =>
    switch (value) {
      'gathering' => MultiplayerState.gathering,
      'waiting_answer' => MultiplayerState.waitingAnswer,
      'hosting' => MultiplayerState.hosting,
      'connecting' => MultiplayerState.connecting,
      'securing' => MultiplayerState.securing,
      'configuring' => MultiplayerState.configuring,
      'connected' => MultiplayerState.connected,
      'reconnecting' => MultiplayerState.reconnecting,
      'failed' => MultiplayerState.failed,
      _ => fallback,
    };

class MultiplayerPeer {
  final String id;
  final int number;
  MultiplayerState state;
  String? error;
  int sent = 0, received = 0;
  final diagnostics = <String, dynamic>{};
  String? errorCode;
  MultiplayerPeer({
    required this.id,
    required this.number,
    this.state = MultiplayerState.connecting,
  });
  bool get connected => state == MultiplayerState.connected;
}

typedef MultiplayerHelperLauncher =
    Future<Process?> Function(String executable, List<String> arguments);

Map<String, dynamic> publicMultiplayerDiagnostics(Map<String, dynamic> data) {
  final result = <String, dynamic>{};
  for (final key in [
    'localFingerprint',
    'remoteFingerprint',
    'selectedLocal',
    'selectedRemote',
    'transport',
  ]) {
    final value = data[key];
    if (value is String) {
      result[key] = value.length > 4096 ? value.substring(0, 4096) : value;
    }
  }
  if (data['identityVerified'] is bool) {
    result['identityVerified'] = data['identityVerified'];
  }
  final rtt = data['iceRTTms'];
  if (rtt is num && rtt.isFinite && rtt >= 0) result['iceRTTms'] = rtt;
  if (data['localCandidates'] case final List candidates) {
    result['localCandidates'] = candidates
        .whereType<String>()
        .where((value) => value.length <= 1024)
        .take(32)
        .toList();
  }
  if (data['stunMappings'] case final List mappings) {
    result['stunMappings'] = [
      for (final mapping in mappings.whereType<Map>().take(16))
        {
          for (final key in ['local', 'server', 'mapped', 'status'])
            if (mapping[key] is String &&
                (mapping[key] as String).length <= 1024)
              key: mapping[key],
        },
    ];
  }
  return result;
}

/// Invitations and IPC credentials live only in memory, never launcher.json,
/// account storage, logs or temporary files.
class MultiplayerController extends ChangeNotifier {
  final String Function() helperPath;
  final MultiplayerHelperLauncher launch;
  final String? supportDirectory;
  MultiplayerSettings settings = const MultiplayerSettings();
  MultiplayerSettings? sessionSettings;
  String? settingsError, errorCode;
  final diagnostics = <String, dynamic>{};
  final diagnosticEvents = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> lastPeerDiagnostics = [];
  int _lastSent = 0, _lastReceived = 0;
  int get diagnosticSent => active ? sent : _lastSent;
  int get diagnosticReceived => active ? received : _lastReceived;
  Future<void> _settingsWrite = Future.value();
  MultiplayerController({
    String Function()? helperPath,
    MultiplayerHelperLauncher? launch,
    this.supportDirectory,
  }) : helperPath = helperPath ?? multiplayerHelperPath,
       launch = launch ?? launchMultiplayerHelper;

  File? get settingsFile => supportDirectory == null
      ? null
      : File(p.join(supportDirectory!, 'multiplayer.json'));

  Future<void> loadSettings() async {
    final file = settingsFile;
    if (file == null) return;
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!await candidate.exists()) continue;
      try {
        settings = MultiplayerSettings.fromJson(
          jsonDecode(await candidate.readAsString()) as Map<String, dynamic>,
        );
        settingsError = null;
        _notify();
        return;
      } catch (_) {
        settingsError = '联机设置无法读取，已使用默认值；原文件已保留';
      }
    }
    _notify();
  }

  Future<void> saveSettings(MultiplayerSettings value) {
    value.validate();
    final snapshot = MultiplayerSettings.fromJson(value.toJson());
    final pending = _settingsWrite.catchError((Object _) {}).then((_) async {
      final file = settingsFile;
      if (file != null) await writeJson(file, snapshot.toJson());
      settings = snapshot;
      settingsError = null;
      _notify();
    });
    _settingsWrite = pending;
    return pending;
  }

  Map<String, dynamic> diagnosticReport() => {
    'format': 'FYL multiplayer diagnostics/1',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'active': active,
    'state': state.name,
    'role': isHost ? 'host' : 'guest',
    'transport': 'ICE/UDP + DTLS + SCTP; Minecraft TCP only; no relay',
    'sessionSettings': sessionSettings?.toJson(),
    'settingsForNextSession': settings.toJson(),
    'diagnostics': publicMultiplayerDiagnostics(diagnostics),
    'errorCode': errorCode,
    'sent': diagnosticSent,
    'received': diagnosticReceived,
    'peers': peers.isEmpty
        ? lastPeerDiagnostics
        : [
            for (final peer in peers.values)
              {
                'number': peer.number,
                'state': peer.state.name,
                'errorCode': peer.errorCode,
                'sent': peer.sent,
                'received': peer.received,
                ...publicMultiplayerDiagnostics(peer.diagnostics),
              },
          ],
    'events': List<Map<String, dynamic>>.of(diagnosticEvents),
  };

  void clearDiagnostics() {
    diagnostics.clear();
    diagnosticEvents.clear();
    lastPeerDiagnostics = [];
    errorCode = null;
    _lastSent = _lastReceived = 0;
    _notify();
  }

  void _record(String type, {String? value, int? peer}) {
    diagnosticEvents.add({
      'time': DateTime.now().toUtc().toIso8601String(),
      'type': type,
      'value': value,
      'peer': ?peer,
    });
    if (diagnosticEvents.length > 100) diagnosticEvents.removeAt(0);
  }

  MultiplayerState state = MultiplayerState.idle;
  bool isHost = true;
  String? ticket, room, error, gameName, _gameAddress;
  String? lastInvitation;
  DateTime? expires;
  int gamePort = 0, sent = 0, received = 0;
  bool multiRoom = false, accepting = false, invitationExpired = false;
  final peers = <String, MultiplayerPeer>{};
  final _removedPeers = <String>{};
  bool get hostingRoom =>
      isHost && multiRoom && state == MultiplayerState.hosting;
  int get connectedPeers => peers.values.where((peer) => peer.connected).length;
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
      launcherMultiplayerEnabled &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _failure(String code) {
    errorCode = code;
    error = multiplayerError(code);
    state = MultiplayerState.failed;
    _record('error', value: code);
    _notify();
  }

  Future<void> host() => _begin(true, null);
  Future<void> join(String invitation) async {
    final parsed = MultiplayerInvitation.parse(invitation, kind: 'offer');
    await _begin(false, parsed.text);
  }

  Future<void> _begin(bool owner, String? invitation) async {
    if (!launcherMultiplayerEnabled) {
      throw UnsupportedError(
        'Experimental multiplayer is disabled in this build',
      );
    }
    if (_disposed || active || _stopping != null) throw StateError('请先断开当前联机');
    // Reserve the session before the first await so stop() can also cancel the
    // file check, rather than letting the old request start a new session later.
    final generation = ++_generation;
    settings.validate();
    sessionSettings = MultiplayerSettings.fromJson(settings.toJson());
    _lastSent = _lastReceived = 0;
    diagnostics.clear();
    diagnosticEvents.clear();
    lastPeerDiagnostics = [];
    errorCode = null;
    _record('start', value: owner ? 'host' : 'guest');
    _starting = true;
    isHost = owner;
    lastInvitation = owner ? null : invitation;
    error = null;
    ticket = null;
    expires = null;
    room = gameName = _gameAddress = null;
    gamePort = sent = received = 0;
    multiRoom = accepting = invitationExpired = false;
    peers.clear();
    _removedPeers.clear();
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
      final executable = p.normalize(p.absolute(helperPath()));
      final exists = await File(executable).exists();
      if (generation != _generation ||
          _disposed ||
          state == MultiplayerState.stopping) {
        return;
      }
      if (!exists) {
        _starting = false;
        _failure('helper_missing');
        return;
      }
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
      _send({
        'type': owner ? 'host' : 'join',
        'ticket': ?invitation,
        'settings': sessionSettings!.toJson(),
      });
    } catch (e) {
      if (generation != _generation ||
          _disposed ||
          state == MultiplayerState.stopping) {
        return;
      }
      final failureCode = errorCode ?? 'helper_closed';
      await stop();
      _failure(failureCode);
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
              if (message['type'] == 'hello' &&
                  message['token'] == token &&
                  message['version'] != 2) {
                _failure('helper_version');
                if (!(_ready?.isCompleted ?? true)) {
                  _ready!.completeError(StateError('helper_version'));
                }
                socket.destroy();
                return;
              }
              if (message['type'] != 'hello' ||
                  message['version'] != 2 ||
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
          _failure('helper_closed');
        }
      },
    );
  }

  void _event(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'ready':
        if (!(_ready?.isCompleted ?? true)) _ready!.complete();
      case 'state':
        state = _connectionState(e['state'] as String?, state);
        _record('state', value: e['state'] as String?);
      case 'diagnostics':
        diagnostics.addAll(
          publicMultiplayerDiagnostics(e['data'] as Map<String, dynamic>),
        );
      case 'ticket':
        ticket = e['text'] as String;
        expires = DateTime.fromMillisecondsSinceEpoch(
          (e['expires'] as int) * 1000,
        );
        room = e['room'] as String;
        if (e['multi'] == true) {
          multiRoom = accepting = true;
          invitationExpired = false;
          error = null;
        }
      case 'room':
        accepting = e['accepting'] == true;
        invitationExpired = e['expired'] == true;
      case 'peer':
        final id = e['id'] as String;
        if (_removedPeers.contains(id)) return;
        final peer = peers.putIfAbsent(
          id,
          () => MultiplayerPeer(id: id, number: e['number'] as int),
        );
        peer.state = _connectionState(e['state'] as String?, peer.state);
        if (e['state'] != null) {
          _record('state', value: e['state'] as String, peer: peer.number);
        }
        if (e['diagnostics'] != null) {
          peer.diagnostics.addAll(
            publicMultiplayerDiagnostics(
              e['diagnostics'] as Map<String, dynamic>,
            ),
          );
        }
        if (e['code'] != null) {
          peer.errorCode = e['code'] as String;
          _record('error', value: peer.errorCode, peer: peer.number);
          peer.error = multiplayerError(e['code'] as String);
        } else if (peer.connected) {
          peer.error = null;
        }
        final uploaded = e['sent'] as int?;
        final downloaded = e['received'] as int?;
        if (uploaded != null && uploaded >= peer.sent) {
          sent += uploaded - peer.sent;
          peer.sent = uploaded;
        }
        if (downloaded != null && downloaded >= peer.received) {
          received += downloaded - peer.received;
          peer.received = downloaded;
        }
        if (e['state'] == 'connecting') error = null;
      case 'peer_removed':
        final id = e['id'] as String;
        _removedPeers.add(id);
        peers.remove(id);
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
        errorCode = e['code'] as String?;
        _record('input_error', value: errorCode);
        error = multiplayerError(e['code'] as String? ?? '');
      case 'error':
        errorCode = e['code'] as String?;
        _record('error', value: errorCode);
        error = multiplayerError(e['code'] as String? ?? '');
        state = MultiplayerState.failed;
        ticket = null;
      case 'stopped':
        if (!(_stopped?.isCompleted ?? true)) _stopped!.complete();
    }
    _notify();
  }

  void answer(String value) {
    if (!isHost || (state != MultiplayerState.waitingAnswer && !hostingRoom)) {
      throw StateError('当前房间不在等待回应');
    }
    final parsed = MultiplayerInvitation.parse(value, kind: 'answer');
    if (multiRoom && (!accepting || expires?.isAfter(DateTime.now()) != true)) {
      throw StateError('当前邀请已停止接纳新人，请重新生成邀请');
    }
    if (multiRoom && parsed.version != 2) {
      throw const FormatException('回应信息不属于当前房间');
    }
    error = null;
    _send({'type': 'answer', 'ticket': parsed.text});
    _notify();
  }

  void sharePort(int port) {
    if (!isHost || (!connected && !hostingRoom) || port < 0 || port > 65535) {
      throw ArgumentError('游戏端口无效');
    }
    _send({'type': 'share', 'port': port});
  }

  void refreshInvitation() {
    if (!hostingRoom) throw StateError('房间尚未创建');
    _send({'type': 'refresh_invitation'});
  }

  void pauseInvitation() {
    if (!hostingRoom) throw StateError('房间尚未创建');
    _send({'type': 'pause_invitation'});
  }

  void removePeer(String id) {
    if (!hostingRoom || !peers.containsKey(id)) return;
    _send({'type': 'remove_peer', 'peer': id});
  }

  void _send(Map<String, dynamic> command) {
    if (_socket == null) throw StateError('网络助手已退出');
    _socket!.write('${jsonEncode(command)}\n');
  }

  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);
  Future<void> _stop() async {
    if (active) {
      _record('stop');
      _lastSent = sent;
      _lastReceived = received;
    }
    if (peers.isNotEmpty) {
      lastPeerDiagnostics = [
        for (final peer in peers.values)
          {
            'number': peer.number,
            'state': peer.state.name,
            'errorCode': peer.errorCode,
            'sent': peer.sent,
            'received': peer.received,
            ...publicMultiplayerDiagnostics(peer.diagnostics),
          },
      ];
    }
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
    lastInvitation = null;
    expires = null;
    gamePort = sent = received = 0;
    multiRoom = accepting = invitationExpired = false;
    peers.clear();
    _removedPeers.clear();
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
