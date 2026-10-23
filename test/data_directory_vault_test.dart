import 'dart:io';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/account_store.dart';
import 'package:free_your_launcher/core/data_directory.dart';
import 'package:free_your_launcher/core/minecraft.dart' show writeJson;
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
