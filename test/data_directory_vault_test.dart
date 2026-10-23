import 'dart:io';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/account_store.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/data_directory.dart';
import 'package:free_your_launcher/core/minecraft.dart' show writeJson;
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:free_your_launcher/ui/launcher_runtime.dart';
import 'package:path/path.dart' as p;

class FixtureVault extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    values[key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => values[key];
  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => values.containsKey(key);
  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => Map.of(values);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      values.clear();
}

void main() {
  testWidgets(
    'legacy startup preserves OS vault accounts without moving data or changing namespaces',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'fyl-legacy-vault-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final previousVault = FlutterSecureStoragePlatform.instance;
      final vault = FixtureVault();
      FlutterSecureStoragePlatform.instance = vault;
      addTearDown(() => FlutterSecureStoragePlatform.instance = previousVault);
      final source = p.join(temporary.path, 'legacy-data');
      final manager = DataDirectoryManager(
        installationDirectory: p.join(temporary.path, 'program'),
        legacyDirectory: () => source,
      );
      const account = LauncherAccount(
        id: 'microsoft:fixture',
        kind: AccountKind.microsoft,
        username: 'Legacy_User',
        uuid: '00000000000000000000000000000001',
      );
      final store = SecureAccountTokenStore(
        supportDirectory: source,
        legacyNamespace: true,
      );
      await tester.runAsync(() async {
        await store.write(
          account.id,
          AccountTokens(
            refreshToken: 'fixture-legacy-refresh',
            accessToken: 'fixture-legacy-access',
            expiresAt: DateTime.utc(2030),
            clientId: LauncherSettings.defaultMicrosoftClientId,
          ),
        );
        await store.writeValue(
          'settings.curseforge-api-key',
          'fixture-legacy-api-key',
        );
        await writeJson(File(p.join(source, 'launcher.json')), {
          'settings': {
            'gameRoot': p.join(source, '.minecraft'),
            'language': 'en',
          },
          'accounts': [account.toJson()],
          'activeAccountId': account.id,
          'instances': [],
          'hasCurseforgeApiKey': true,
        });
      });
      LauncherController? active;
      await tester.pumpWidget(
        LauncherRuntime(
          directories: manager,
          platform: HostPlatform(Platform.isMacOS ? 'osx' : 'linux', 'x86_64'),
          nativeWindow: false,
          onReady: (value) => active = value,
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (active == null && DateTime.now().isBefore(deadline)) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(active, isNotNull);
      expect(find.byType(LauncherApp), findsOneWidget);
      expect(active!.supportDirectory, source);
      expect(active!.activeAccount!.id, account.id);
      expect(active!.settings.curseforgeApiKey, 'fixture-legacy-api-key');
      await tester.runAsync(() async {
        expect(
          (await active!.tokenStore.read(account.id))!.refreshToken,
          'fixture-legacy-refresh',
        );
        expect(
          await File(p.join(source, 'credentials', 'profile-id')).exists(),
          isFalse,
        );
        expect(await manager.configuration.exists(), isFalse);
        expect(await Directory(manager.defaultDirectory).exists(), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      expect(tester.takeException(), isNull);
    },
    skip: Platform.isWindows,
  );

  test(
    'OS vault credentials stay scoped to a profile and survive physical data migration',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'fyl-vault-profile-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final previous = FlutterSecureStoragePlatform.instance;
      final vault = FixtureVault();
      FlutterSecureStoragePlatform.instance = vault;
      addTearDown(() => FlutterSecureStoragePlatform.instance = previous);
      final source = p.join(temporary.path, 'source');
      final target = p.join(temporary.path, 'destination');
      final first = SecureAccountTokenStore(supportDirectory: source);
      final companion = SecureAccountTokenStore(supportDirectory: source);
      await Future.wait([
        first.writeValue('account', 'fixture-session'),
        companion.writeValue('settings.curseforge-api-key', 'fixture-api-key'),
      ]);
      expect(
        vault.values.keys.map((key) => key.split('.')[2]).toSet(),
        hasLength(1),
      );
      final another = SecureAccountTokenStore(
        supportDirectory: p.join(temporary.path, 'other'),
      );
      expect(await another.readValue('account'), isNull);
      await writeJson(File(p.join(source, 'launcher.json')), {
        'settings': {},
        'instances': [],
        'accounts': [],
      });
      final manager = DataDirectoryManager(
        installationDirectory: p.join(temporary.path, 'program'),
        legacyDirectory: () => null,
      );
      await manager.select(target, source: source, migrate: true);
      await manager.activate();
      expect(
        await SecureAccountTokenStore(
          supportDirectory: target,
        ).readValue('account'),
        'fixture-session',
      );
      expect(
        await SecureAccountTokenStore(
          supportDirectory: target,
        ).readValue('settings.curseforge-api-key'),
        'fixture-api-key',
      );
      expect(await manager.completeMigration(), isNull);
      expect(
        await SecureAccountTokenStore(
          supportDirectory: source,
        ).readValue('account'),
        isNull,
      );
      expect(
        vault.values.values,
        containsAll(['fixture-session', 'fixture-api-key']),
      );
    },
    skip: Platform.isWindows,
  );
}
