import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'accounts.dart';
import 'models.dart';
import 'windows_dpapi.dart';

class SecureAccountTokenStore implements AccountTokenStore {
  final String? supportDirectory;
  SecureAccountTokenStore({this.supportDirectory});
  String _key(String id) => 'fyl.account.$id';
  Map<String, String> get _options => Platform.isMacOS
      ? {
          'usesDataProtectionKeychain': 'false',
          'accountName': 'free_your_launcher',
        }
      : {'accountName': 'free_your_launcher'};
  Future<File> _windowsFile(String id) async {
    final directory =
        supportDirectory ?? (await getApplicationSupportDirectory()).path;
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
          key: _key(id),
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
        key: _key(id),
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
        key: _key(id),
        options: _options,
      );
    }
  }
}
