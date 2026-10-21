import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// User-bound Windows encryption. Keys are managed by Windows, never by FYL.
/// No plaintext credential is written to disk, including temporary files.
class WindowsDpapi {
  static const _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN from dpapi.h.
  static Uint8List transform(
    List<int> bytes,
    String accountKey, {
    required bool encrypt,
  }) {
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final output = calloc<CRYPT_INTEGER_BLOB>();
    final entropy = calloc<CRYPT_INTEGER_BLOB>();
    final entropyBytes = utf8.encode('free_your_launcher/$accountKey');
    input.ref.cbData = bytes.length;
    input.ref.pbData = calloc<Uint8>(bytes.length);
    entropy.ref.cbData = entropyBytes.length;
    entropy.ref.pbData = calloc<Uint8>(entropyBytes.length);
    input.ref.pbData.asTypedList(bytes.length).setAll(0, bytes);
    entropy.ref.pbData.asTypedList(entropyBytes.length).setAll(0, entropyBytes);
    try {
      final result = encrypt
          ? CryptProtectData(input, null, entropy, null, _uiForbidden, output)
          : CryptUnprotectData(
              input,
              null,
              entropy,
              null,
              _uiForbidden,
              output,
            );
      if (!result.value) {
        throw StateError(
          'Windows 无法${encrypt ? '保护' : '解密'}登录凭据（${result.error}）。请重新登录。',
        );
      }
      return Uint8List.fromList(
        output.ref.pbData.asTypedList(output.ref.cbData),
      );
    } finally {
      input.ref.pbData
          .asTypedList(input.ref.cbData)
          .fillRange(0, input.ref.cbData, 0);
      entropy.ref.pbData
          .asTypedList(entropy.ref.cbData)
          .fillRange(0, entropy.ref.cbData, 0);
      calloc.free(input.ref.pbData);
      calloc.free(entropy.ref.pbData);
      if (output.ref.pbData != nullptr) {
        output.ref.pbData
            .asTypedList(output.ref.cbData)
            .fillRange(0, output.ref.cbData, 0);
        LocalFree(HLOCAL(output.ref.pbData));
      }
      calloc.free(input);
      calloc.free(output);
      calloc.free(entropy);
    }
  }

  static Future<String?> read(File file, String key) async {
    if (!await file.exists()) return null;
    if (await file.length() > 1024 * 1024) throw StateError('登录凭据文件无效，请重新登录。');
    final bytes = transform(await file.readAsBytes(), key, encrypt: false);
    try {
      return utf8.decode(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static Future<void> write(File file, String key, String value) async {
    final encrypted = transform(utf8.encode(value), key, encrypt: true);
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsBytes(encrypted, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
