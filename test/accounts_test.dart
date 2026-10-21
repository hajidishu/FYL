import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/microsoft_auth.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;
import 'account_test_support.dart';

class DeferredRefresh extends MicrosoftAuth {
  final started = Completer<void>();
  final result = Completer<MicrosoftLoginResult>();
  @override
  Future<MicrosoftLoginResult> refresh(
    AccountTokens tokens,
    CancellationToken token,
  ) {
    started.complete();
    return result.future;
  }
}

void main() {
  late Directory directory;
  late LauncherController controller;
  late MemoryTokenStore store;
  const online = LauncherAccount(
    id: 'microsoft:12345678901234567890123456789012',
    kind: AccountKind.microsoft,
    username: 'Online_User',
    uuid: '12345678901234567890123456789012',
  );
  AccountTokens tokens({bool expired = false}) => AccountTokens(
    refreshToken: 'secret-refresh',
    accessToken: 'secret-access',
    expiresAt: DateTime.now().add(Duration(hours: expired ? -1 : 1)),
    clientId: '11111111-1111-1111-1111-111111111111',
    xuid: '100000',
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-accounts-');
    store = MemoryTokenStore();
    controller = LauncherController(
      supportDirectory: directory.path,
      platform: const HostPlatform('windows', 'x86_64'),
      tokenStore: store,
    );
    await controller.initialize();
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'multiple offline and Microsoft accounts persist together without plaintext tokens',
    () async {
      await controller.addOfflineAccount('First_User');
      await controller.addOfflineAccount('Second_User');
      await controller.addMicrosoftAccount(
        MicrosoftLoginResult(online, tokens()),
      );
      expect(controller.accounts.length, 3);
      final jsonText = await File(
        p.join(directory.path, 'launcher.json'),
      ).readAsString();
      expect(jsonText, isNot(contains('secret-')));
      expect(store.values[online.id]!.refreshToken, 'secret-refresh');
      final restored = LauncherController(
        supportDirectory: directory.path,
        platform: controller.platform,
        tokenStore: store,
      );
      await restored.initialize();
      addTearDown(restored.dispose);
      expect(restored.activeAccount!.id, online.id);
      await restored.switchAccount(restored.accounts.first);
      final session = await restored.prepareSession();
      expect(session.online, isFalse);
      expect(session.username, 'First_User');
      expect(session.uuid, offlineUuid('First_User'));
    },
  );
  test(
    're-adding an offline account selects it without duplicating it',
    () async {
      await controller.addOfflineAccount('Player_One');
      await controller.addOfflineAccount('Player_Two');
      await controller.addOfflineAccount('Player_One');
      expect(controller.accounts.length, 2);
      expect(controller.activeAccount!.username, 'Player_One');
      await expectLater(
        controller.addOfflineAccount('ab'),
        throwsArgumentError,
      );
    },
  );
  test('legacy username migrates to the same offline UUID', () async {
    await writeJson(File(p.join(directory.path, 'launcher.json')), {
      'settings': controller.settings.toJson()..['username'] = 'Legacy_User',
      'instances': [],
    });
    await controller.initialize();
    expect(controller.accounts.single.uuid, offlineUuid('Legacy_User'));
    final saved =
        jsonDecode(
              await File(
                p.join(directory.path, 'launcher.json'),
              ).readAsString(),
            )
            as Json;
    expect(saved['schemaVersion'], 2);
    expect(saved['accounts'], hasLength(1));
  });
  test(
    'switching account during refresh does not mix tokens and identity',
    () async {
      final refresh = DeferredRefresh();
      final active = LauncherController(
        supportDirectory: directory.path,
        platform: controller.platform,
        tokenStore: store,
        authFactory: () => refresh,
      );
      addTearDown(active.dispose);
      await active.addMicrosoftAccount(
        MicrosoftLoginResult(online, tokens(expired: true)),
      );
      await active.addOfflineAccount('Other_User');
      final other = active.activeAccount!;
      await active.switchAccount(online);
      final sessionFuture = active.prepareSession();
      await refresh.started.future;
      await active.switchAccount(other);
      refresh.result.complete(MicrosoftLoginResult(online, tokens()));
      final session = await sessionFuture;
      expect(session.username, 'Online_User');
      expect(session.accessToken, 'secret-access');
      expect(active.activeAccount!.id, other.id);
    },
  );
  test(
    'Microsoft launch arguments use the real session and offline UUID remains separate',
    () {
      final instance = GameInstance(
        id: 'test',
        name: 'Test',
        version: '1.21.1',
        root: directory.path,
        isolated: true,
        javaMajor: 21,
      );
      final metadata = <String, dynamic>{
        'id': 'fabric-loader-1.21.1',
        'mainClass': 'Main',
        'libraries': [],
        'arguments': {
          'game': [
            '--username',
            r'${auth_player_name}',
            '--uuid',
            r'${auth_uuid}',
            '--accessToken',
            r'${auth_access_token}',
            '--userType',
            r'${user_type}',
            '--clientId',
            r'${clientid}',
            '--xuid',
            r'${auth_xuid}',
          ],
        },
      };
      final command = buildLaunchCommand(
        instance,
        metadata,
        controller.settings,
        controller.platform,
        'java',
        session: GameSession(
          username: online.username,
          uuid: online.uuid,
          online: true,
          accessToken: 'real-mc-token',
          clientId: 'fyl-app',
          xuid: '100000',
        ),
      );
      expect(
        command.arguments,
        containsAll([
          'Online_User',
          online.uuid,
          'real-mc-token',
          'msa',
          'fyl-app',
          '100000',
        ]),
      );
      expect(command.arguments, isNot(contains(offlineUuid(online.username))));
    },
  );
}
