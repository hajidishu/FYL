import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/multiplayer.dart';
import 'package:free_your_launcher/core/multiplayer_settings.dart';
import 'package:free_your_launcher/core/build_info.dart';

import 'multiplayer_test.dart' show HelperFixture;

Future<void> delivered(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Expected multiplayer event was not delivered');
}

void main() => group(
  'experimental multiplayer settings',
  multiplayerSettingsTests,
  skip: !launcherMultiplayerEnabled,
);

void multiplayerSettingsTests() {
  test('old helpers cannot silently ignore network settings', () async {
    final root = await Directory.systemTemp.createTemp('fyl-helper-version-');
    final file = File('${root.path}/helper');
    await file.writeAsString('fixture');
    final fixture = HelperFixture(version: 1);
    final network = MultiplayerController(
      helperPath: () => file.path,
      launch: fixture.launch,
    );
    addTearDown(() async {
      await network.stop();
      network.dispose();
      fixture.dispose();
      await root.delete(recursive: true);
    });
    await network.host();
    expect(network.state, MultiplayerState.failed);
    expect(network.errorCode, 'helper_version');
    expect(network.error, contains('联机组件版本过旧'));
    expect(fixture.commands, isEmpty);
  });

  test(
    'settings accept IPv6 STUN and reject unsupported tunnels and invalid ranges',
    () {
      const MultiplayerSettings(
        stunServers: ['stun:[2001:db8::1]:3478'],
      ).validate();
      const MultiplayerSettings(stunServers: []).validate();
      for (final change in <Map<String, dynamic>>[
        {'localPort': 65536},
        {'maxPeers': 17},
        {'invitationMinutes': 11},
        {'stunTimeout': 0},
        {'connectTimeout': 1},
        {'addressFamily': 'tcp'},
        {
          'stunServers': ['turn:example.com:3478'],
        },
        {
          'stunServers': ['stun:user:password@example.com:3478'],
        },
        {
          'stunServers': ['stun:example.com:3478?transport=tcp'],
        },
      ]) {
        expect(
          () => MultiplayerSettings.fromJson(change),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'preferences persist separately, recover from backup and leave main settings intact',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fyl-network-settings-',
      );
      final main = File('${root.path}/launcher.json');
      await main.writeAsString('{"keep":"main settings"}');
      final first = MultiplayerController(supportDirectory: root.path);
      final restored = MultiplayerController(supportDirectory: root.path);
      addTearDown(() async {
        first.dispose();
        restored.dispose();
        await root.delete(recursive: true);
      });
      await first.saveSettings(
        const MultiplayerSettings(
          localPort: 40001,
          maxPeers: 4,
          stunServers: [],
        ),
      );
      await restored.loadSettings();
      expect(restored.settings.localPort, 40001);
      expect(restored.settings.stunServers, isEmpty);
      await first.saveSettings(const MultiplayerSettings(localPort: 40002));
      await File('${root.path}/multiplayer.json').writeAsString('broken');
      await restored.loadSettings();
      expect(restored.settings.localPort, 40001);
      expect(
        await File('${root.path}/multiplayer.json').readAsString(),
        'broken',
      );
      expect(await main.readAsString(), '{"keep":"main settings"}');
    },
  );

  test(
    'live sessions retain their settings and diagnostic reports exclude credentials',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fyl-network-diagnostics-',
      );
      final helper = File('${root.path}/helper');
      await helper.writeAsString('fixture');
      final fixture = HelperFixture();
      final network = MultiplayerController(
        supportDirectory: root.path,
        helperPath: () => helper.path,
        launch: fixture.launch,
      );
      addTearDown(() async {
        await network.stop();
        network.dispose();
        fixture.dispose();
        await root.delete(recursive: true);
      });
      await network.saveSettings(
        const MultiplayerSettings(
          addressFamily: 'ipv4',
          localPort: 40001,
          maxPeers: 4,
        ),
      );
      await network.host();
      await delivered(() => fixture.commands.any((c) => c['type'] == 'host'));
      final request = fixture.commands.singleWhere((c) => c['type'] == 'host');
      expect((request['settings'] as Map)['localPort'], 40001);
      expect((request['settings'] as Map)['maxPeers'], 4);
      await network.saveSettings(
        const MultiplayerSettings(localPort: 40002, maxPeers: 8),
      );
      expect(network.active, isTrue);
      expect(network.sessionSettings!.localPort, 40001);
      expect(network.settings.localPort, 40002);
      expect(fixture.commands.any((c) => c['type'] == 'stop'), isFalse);
      fixture.send({
        'type': 'diagnostics',
        'data': {
          'localCandidates': ['1 1 udp 123 192.0.2.1 40001 typ host'],
          'selectedRemote': '2 1 udp 123 198.51.100.1 45000 typ srflx',
          'identityVerified': true,
          'iceRTTms': 20.5,
          'password': 'DO-NOT-EXPORT',
          'secret': 'DO-NOT-EXPORT',
          'stunMappings': [
            {
              'server': '192.0.2.2:3478',
              'status': 'success',
              'password': 'DO-NOT-EXPORT',
            },
          ],
        },
      });
      fixture.send({
        'type': 'ticket',
        'room': 'room',
        'text': 'FYL2:PRIVATE-INVITATION',
        'expires':
            DateTime.now()
                .add(const Duration(minutes: 5))
                .millisecondsSinceEpoch ~/
            1000,
      });
      await delivered(() => network.diagnostics['iceRTTms'] == 20.5);
      fixture.send({'type': 'stats', 'sent': 1234, 'received': 5678});
      await delivered(() => network.sent == 1234);
      final report = jsonEncode(network.diagnosticReport());
      expect(report, contains('198.51.100.1'));
      expect(report, contains('40001'));
      expect(report, isNot(contains('DO-NOT-EXPORT')));
      expect(report, isNot(contains('PRIVATE-INVITATION')));
      expect(
        await network.settingsFile!.readAsString(),
        isNot(contains('PRIVATE-INVITATION')),
      );
      await network.stop();
      expect(network.diagnostics['identityVerified'], isTrue);
      expect(network.diagnosticReport()['sent'], 1234);
      expect(network.diagnosticReport()['received'], 5678);
      network.clearDiagnostics();
      expect(network.diagnosticEvents, isEmpty);
      expect(network.diagnostics, isEmpty);
    },
  );
}
