import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/multiplayer.dart';
import 'package:free_your_launcher/core/multiplayer_invitation.dart';

String invitation({
  String kind = 'offer',
  DateTime? expires,
  String protocol = 'minecraft-tcp',
  int version = 1,
  String peer = 'AAAAAAAAAAAAAAAAAAAAAA',
}) {
  final data = {
    'v': version,
    'd': protocol,
    't': kind,
    'r': 'AAAAAAAAAAAAAAAAAAAAAA',
    'e':
        (expires ?? DateTime.now().add(const Duration(minutes: 5)))
            .millisecondsSinceEpoch ~/
        1000,
    'u': 'user',
    'p': 'aaaaaaaaaaaaaaaaaaaaaaaa',
    'f': '0' * 64,
    'c': ['1 1 udp 2130706431 198.51.100.1 50000 typ host'],
    if (version == 2 && kind == 'answer') 'i': peer,
  };
  return 'FYL$version:${base64Url.encode(utf8.encode(jsonEncode(data))).replaceAll('=', '')}';
}

class HelperFixture {
  Socket? socket;
  final commands = <Map<String, dynamic>>[];
  final stopped = Completer<void>();
  Future<Process?> launch(String _, List<String> arguments) async {
    final port = int.parse(arguments[arguments.indexOf('--control-port') + 1]);
    final token = arguments[arguments.indexOf('--control-token') + 1];
    final connection = socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
    );
    connection
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) async {
          final message = jsonDecode(line) as Map<String, dynamic>;
          commands.add(message);
          switch (message['type']) {
            case 'auth':
              send({'type': 'ready'});
            case 'host':
              send({'type': 'state', 'state': 'waiting_answer'});
            case 'stop':
              send({'type': 'stopped'});
              await connection.flush();
              await connection.close();
              if (!stopped.isCompleted) stopped.complete();
          }
        });
    send({'type': 'hello', 'version': 1, 'token': token});
    return null;
  }

  void send(Map<String, dynamic> value) =>
      socket!.write('${jsonEncode(value)}\n');
  void dispose() => socket?.destroy();
}

void main() {
  test(
    'shared invitations validate their version and per-friend identifier',
    () {
      expect(
        MultiplayerInvitation.parse(
          invitation(version: 2),
          kind: 'offer',
        ).version,
        2,
      );
      expect(
        MultiplayerInvitation.parse(
          invitation(version: 2, kind: 'answer'),
          kind: 'answer',
        ).version,
        2,
      );
      expect(
        () => MultiplayerInvitation.parse(
          invitation(version: 2, kind: 'answer', peer: 'invalid'),
          kind: 'answer',
        ),
        throwsFormatException,
      );
      expect(
        () => MultiplayerInvitation.parse(
          invitation().replaceFirst('FYL1:', 'FYL2:'),
          kind: 'offer',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'room IPC keeps peer failures separate and remains open for more replies',
    () async {
      final temporary = await Directory.systemTemp.createTemp('fyl-room-ipc-');
      final helper = File('${temporary.path}/helper');
      await helper.writeAsString('fixture');
      final fixture = HelperFixture();
      final controller = MultiplayerController(
        helperPath: () => helper.path,
        launch: fixture.launch,
      );
      addTearDown(() async {
        await controller.stop();
        controller.dispose();
        fixture.dispose();
        await temporary.delete(recursive: true);
      });
      Future<void> waitFor(bool Function() predicate) async {
        for (var i = 0; i < 200; i++) {
          if (predicate()) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        fail('Room IPC event was not delivered');
      }

      await controller.host();
      await waitFor(() => controller.state == MultiplayerState.waitingAnswer);
      fixture.send({
        'type': 'ticket',
        'multi': true,
        'text': invitation(version: 2),
        'room': 'room',
        'expires':
            DateTime.now()
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch ~/
            1000,
      });
      fixture.send({'type': 'room', 'accepting': true, 'expired': false});
      fixture.send({'type': 'state', 'state': 'hosting'});
      await waitFor(() => controller.hostingRoom);
      controller.answer(invitation(version: 2, kind: 'answer'));
      fixture.send({
        'type': 'peer',
        'id': 'one',
        'number': 1,
        'state': 'connected',
      });
      fixture.send({
        'type': 'peer',
        'id': 'two',
        'number': 2,
        'state': 'connecting',
      });
      fixture.send({
        'type': 'peer',
        'id': 'one',
        'number': 1,
        'sent': 100,
        'received': 200,
      });
      fixture.send({
        'type': 'peer',
        'id': 'two',
        'number': 2,
        'state': 'failed',
        'code': 'direct_failed',
      });
      await waitFor(
        () => controller.peers['two']?.state == MultiplayerState.failed,
      );
      expect(controller.hostingRoom, isTrue);
      expect(controller.connectedPeers, 1);
      expect(controller.error, isNull);
      expect(controller.peers['two']!.error, contains('无法建立直连'));
      expect(controller.sent, 100);
      controller.answer(
        invitation(version: 2, kind: 'answer', peer: 'AQEBAQEBAQEBAQEBAQEBAQ'),
      );
      controller.sharePort(25565);
      controller.removePeer('two');
      await waitFor(
        () => fixture.commands.any((c) => c['type'] == 'remove_peer'),
      );
      expect(
        fixture.commands.where((c) => c['type'] == 'answer'),
        hasLength(2),
      );
      expect(fixture.commands.last['peer'], 'two');
      fixture.send({'type': 'peer_removed', 'id': 'two'});
      fixture.send({
        'type': 'peer',
        'id': 'two',
        'number': 2,
        'state': 'connected',
      });
      await waitFor(() => !controller.peers.containsKey('two'));
      fixture.send({'type': 'room', 'accepting': false, 'expired': true});
      await waitFor(() => controller.invitationExpired);
      expect(controller.connectedPeers, 1);
      expect(
        () => controller.answer(invitation(version: 2, kind: 'answer')),
        throwsStateError,
      );
      controller.refreshInvitation();
      await waitFor(
        () => fixture.commands.any((c) => c['type'] == 'refresh_invitation'),
      );
      expect(controller.sent, 100);
    },
  );

  test(
    'manual invitation accepts wrapped text and rejects expired or other protocols',
    () {
      final text = invitation();
      expect(
        MultiplayerInvitation.parse(
          '${text.substring(0, 40)}\n${text.substring(40)}',
          kind: 'offer',
        ).text,
        text,
      );
      expect(
        () => MultiplayerInvitation.parse(text, kind: 'answer'),
        throwsFormatException,
      );
      expect(
        () => MultiplayerInvitation.parse(
          invitation(
            expires: DateTime.now().subtract(const Duration(seconds: 1)),
          ),
          kind: 'offer',
        ),
        throwsFormatException,
      );
      expect(
        () => MultiplayerInvitation.parse(
          invitation(protocol: 'system-vpn'),
          kind: 'offer',
        ),
        throwsFormatException,
      );
      expect(
        () => MultiplayerInvitation.parse('FYL1:${'a' * 65536}', kind: 'offer'),
        throwsFormatException,
      );
    },
  );

  test(
    'helper IPC authenticates, exposes only a local game address and acknowledges shutdown',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'fyl-multiplayer-',
      );
      final helper = File('${temporary.path}/helper');
      await helper.writeAsString('fixture');
      final fixture = HelperFixture();
      final controller = MultiplayerController(
        helperPath: () => helper.path,
        launch: fixture.launch,
      );
      addTearDown(() async {
        await controller.stop();
        controller.dispose();
        fixture.dispose();
        await temporary.delete(recursive: true);
      });
      await controller.host();
      expect(controller.active, isTrue);
      expect(fixture.commands.first['type'], 'auth');
      final connected = Completer<void>();
      controller.addListener(() {
        if (controller.connected && !connected.isCompleted) {
          connected.complete();
        }
      });
      controller.isHost = false;
      fixture.send({'type': 'state', 'state': 'connected'});
      await connected.future;
      final addressReady = Completer<void>();
      controller.addListener(() {
        if (controller.gameAddress != null && !addressReady.isCompleted) {
          addressReady.complete();
        }
      });
      fixture.send({
        'type': 'game',
        'port': 25565,
        'name': 'World',
        'address': '127.0.0.1:45000',
      });
      await addressReady.future;
      expect(controller.gameAddress, '127.0.0.1:45000');
      await controller.stop();
      await fixture.stopped.future;
      expect(controller.active, isFalse);
      expect(controller.ticket, isNull);
      expect(controller.gameAddress, isNull);
      expect(controller.state, MultiplayerState.idle);
    },
  );

  test('invalid invitation never starts a child process', () async {
    var launched = false;
    final controller = MultiplayerController(
      launch: (_, _) async {
        launched = true;
        return null;
      },
    );
    addTearDown(controller.dispose);
    await expectLater(
      controller.join('not an invitation'),
      throwsFormatException,
    );
    expect(launched, isFalse);
    expect(controller.active, isFalse);
  });

  test('stopping immediately cancels the pending helper file check', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'fyl-cancel-start-',
    );
    final helper = File('${temporary.path}/helper');
    await helper.writeAsString('fixture');
    final fixture = HelperFixture();
    var launches = 0;
    final controller = MultiplayerController(
      helperPath: () => helper.path,
      launch: (path, arguments) {
        launches++;
        return fixture.launch(path, arguments);
      },
    );
    addTearDown(() async {
      await controller.stop();
      controller.dispose();
      fixture.dispose();
      await temporary.delete(recursive: true);
    });
    final starting = controller.host();
    await controller.stop();
    await starting;
    expect(launches, 0);
    expect(controller.active, isFalse);
    expect(controller.state, MultiplayerState.idle);
  });
}
