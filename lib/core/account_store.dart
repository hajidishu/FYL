import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path/path.dart' as p;

import 'accounts.dart';
import 'models.dart';
import 'windows_dpapi.dart';
import 'data_directory.dart';

class SecureAccountTokenStore implements AccountTokenStore {
  final String? supportDirectory;
  final bool legacyNamespace;
  Future<String>? _profile;
  static final _profiles = <String, Future<String>>{};
  SecureAccountTokenStore({
    this.supportDirectory,
    this.legacyNamespace = false,
  });
  String _key(String id) => 'fyl.account.$id';
  Future<String> _secureKey(String id) async {
    if (legacyNamespace) return _key(id);
    final profile = await (_profile ??= _sharedProfile());
    return 'fyl.profile.$profile.account.$id';
  }

  Future<String> _sharedProfile() async {
    final directory = p.normalize(supportDirectory ?? defaultDataDirectory());
    final pending = _profiles.putIfAbsent(directory, _readProfile);
    try {
      return await pending;
    } finally {
      if (identical(_profiles[directory], pending)) _profiles.remove(directory);
    }
  }

  Future<String> _readProfile() async {
    final file = File(
      p.join(
        supportDirectory ?? defaultDataDirectory(),
        'credentials',
        'profile-id',
      ),
    );
    if (await file.exists()) {
      final value = (await file.readAsString()).trim();
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
        throw StateError('凭据目录标识无效。');
      }
      return value;
    }
    final random = Random.secure();
    final value = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await file.parent.create(recursive: true);
    await file.writeAsString(value, flush: true);
    return value;
  }

  Map<String, String> get _options => Platform.isMacOS
      ? {
          'usesDataProtectionKeychain': 'false',
          'accountName': 'free_your_launcher',
        }
      : {'accountName': 'free_your_launcher'};
  Future<File> _windowsFile(String id) async {
    final directory = supportDirectory ?? defaultDataDirectory();
    return File(
      p.join(
        directory,
        'credentials',
        '${sha256.convert(utf8.encode(_key(id)))}.dpapi',
      ),
    );
  }

  @override
  Future<AccountTokens?> read(String id) async {
    final value = await readValue(id);
    return value == null
        ? null
        : AccountTokens.fromJson(jsonDecode(value) as Json);
  }

  Future<String?> readValue(String id) async => Platform.isWindows
      ? await WindowsDpapi.read(await _windowsFile(id), _key(id))
      : await FlutterSecureStoragePlatform.instance.read(
          key: await _secureKey(id),
          options: _options,
        );

  @override
  Future<void> write(String id, AccountTokens tokens) async {
    await writeValue(id, jsonEncode(tokens.toJson()));
  }

  Future<void> writeValue(String id, String value) async {
    if (Platform.isWindows) {
      await WindowsDpapi.write(await _windowsFile(id), _key(id), value);
    } else {
      await FlutterSecureStoragePlatform.instance.write(
        key: await _secureKey(id),
        value: value,
        options: _options,
      );
    }
  }

  @override
  Future<void> delete(String id) async {
    if (Platform.isWindows) {
      final file = await _windowsFile(id);
      if (await file.exists()) await file.delete();
    } else {
      await FlutterSecureStoragePlatform.instance.delete(
        key: await _secureKey(id),
        options: _options,
      );
    }
  }
}
