import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/account_store.dart';
import 'package:free_your_launcher/core/windows_dpapi.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'Windows credentials are encrypted, support large tokens and replace atomically',
    () async {
      final directory = await Directory.systemTemp.createTemp('fyl-dpapi-');
      addTearDown(() => directory.delete(recursive: true));
      final store = SecureAccountTokenStore(supportDirectory: directory.path);
      final tokens = AccountTokens(
        refreshToken: 'test-refresh-' * 1000,
        accessToken: 'test-access',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        clientId: 'test-client',
      );
      await store.write('account-one', tokens);
      expect(
        (await store.read('account-one'))!.refreshToken,
        tokens.refreshToken,
      );
      final file =
          (await Directory(
                p.join(directory.path, 'credentials'),
              ).list().toList()).single
              as File;
      expect(
        String.fromCharCodes(await file.readAsBytes()),
        isNot(contains('test-refresh')),
      );
      final replacement = AccountTokens(
        refreshToken: 'new-refresh',
        accessToken: 'new-access',
        expiresAt: tokens.expiresAt,
        clientId: tokens.clientId,
      );
      await store.write('account-one', replacement);
      expect((await store.read('account-one'))!.refreshToken, 'new-refresh');
      expect(
        await Directory(p.join(directory.path, 'credentials')).list().length,
        1,
      );
      await store.delete('account-one');
      expect(await store.read('account-one'), isNull);
    },
    skip: !Platform.isWindows,
  );

  test(
    'DPAPI ciphertext is bound to the account key and rejects a changed blob',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fyl-dpapi-binding-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File(p.join(directory.path, 'token.dpapi'));
      await WindowsDpapi.write(file, 'account-one', 'private-token');
      expect(await WindowsDpapi.read(file, 'account-one'), 'private-token');
      await expectLater(
        WindowsDpapi.read(file, 'different-account'),
        throwsStateError,
      );
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 8] ^= 1;
      await file.writeAsBytes(bytes);
      await expectLater(
        WindowsDpapi.read(file, 'account-one'),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
    },
    skip: !Platform.isWindows,
  );
}
