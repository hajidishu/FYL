import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;

void main() {
  late HttpServer server;
  late Directory temporary;
  late OfficialNetwork network;
  late String base;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fyl-network-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    network = OfficialNetwork(
      LauncherSettings(gameRoot: temporary.path, downloadRetries: 1),
      allowLocalhost: true,
    );
  });
  tearDown(() async {
    network.close();
    await server.close(force: true);
    await temporary.delete(recursive: true);
  });
  test(
    'download verifies, reuses good cache and repairs corrupt cache',
    () async {
      final data = utf8.encode('a complete game dependency');
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.add(data);
        await request.response.close();
      });
      final destination = p.join(temporary.path, 'nested', 'file.jar');
      final file = DownloadFile(
        '$base/library',
        destination,
        hash: sha1.convert(data).toString(),
        size: data.length,
      );
      await network.download(file, CancellationToken());
      expect(await File(destination).readAsBytes(), data);
      await network.download(file, CancellationToken());
      expect(requests, 1);
      await File(destination).writeAsBytes(List.filled(data.length, 0));
      await network.download(file, CancellationToken());
      expect(requests, 2);
      expect(await File(destination).readAsBytes(), data);
      expect(await File('$destination.part').exists(), isFalse);
    },
  );
  test('bad integrity retries without publishing incomplete files', () async {
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.write('corrupt');
      await request.response.close();
    });
    final destination = p.join(temporary.path, 'file.jar');
    await expectLater(
      network.download(
        DownloadFile('$base/library', destination, hash: '0' * 40),
        CancellationToken(),
      ),
      throwsFormatException,
    );
    expect(requests, 2);
    expect(await File(destination).exists(), isFalse);
    expect(await File('$destination.part').exists(), isFalse);
  });
  test(
    'community hash verification remains mandatory and alternatives work without retries',
    () async {
      final bytes = utf8.encode('verified community file');
      network.settings.downloadRetries = 0;
      network.settings.verifyDownloads = false;
      server.listen((request) async {
        if (request.uri.path == '/missing') {
          request.response.statusCode = 404;
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      });
      final destination = p.join(temporary.path, 'community.jar');
      await network.download(
        DownloadFile(
          '$base/missing',
          destination,
          alternativeUrls: ['$base/file'],
          hashes: {'sha512': sha512.convert(bytes).toString()},
          requireIntegrity: true,
        ),
        CancellationToken(),
      );
      expect(await File(destination).readAsBytes(), bytes);
      await expectLater(
        network.download(
          DownloadFile(
            '$base/file',
            destination,
            hashes: {'sha512': '0' * 128},
            requireIntegrity: true,
          ),
          CancellationToken(),
        ),
        throwsFormatException,
      );
      expect(await File(destination).readAsBytes(), bytes);
    },
  );
  test('metadata hash stays mandatory when download checking is off', () async {
    server.listen((request) async {
      request.response.write('{"version":"test"}');
      await request.response.close();
    });
    network.settings.verifyDownloads = false;
    await expectLater(
      network.json('$base/metadata', expectedHash: '0' * 40),
      throwsFormatException,
    );
    expect(await network.json('$base/metadata'), {'version': 'test'});
  });
  test('parallel cancellation removes partial files', () async {
    server.listen((request) async {
      request.response.add(List.filled(8192, 42));
      await request.response.close();
    });
    final token = CancellationToken();
    final downloads = List.generate(
      12,
      (i) => DownloadFile('$base/$i', p.join(temporary.path, '$i.jar')),
    );
    await expectLater(
      network.downloadAll(downloads, token, onBytes: (_) => token.cancel()),
      throwsA(isA<Cancelled>()),
    );
    expect(
      await temporary
          .list(recursive: true)
          .where((entry) => entry.path.endsWith('.part'))
          .isEmpty,
      isTrue,
    );
  });
  test('production networking rejects unofficial URLs', () async {
    final production = OfficialNetwork(network.settings);
    addTearDown(production.close);
    await expectLater(
      production.json('https://example.com/manifest.json'),
      throwsFormatException,
    );
    await expectLater(
      production.json('http://libraries.minecraft.net/library.jar'),
      throwsFormatException,
    );
  });

  test('cancellation interrupts a response that stops sending data', () async {
    final received = Completer<void>();
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 1000000;
      request.response.add(List.filled(8192, 42));
      await request.response.flush();
    });
    final token = CancellationToken();
    final operation = network.download(
      DownloadFile('$base/stalled', p.join(temporary.path, 'stalled.jar')),
      token,
      onBytes: (_) {
        if (!received.isCompleted) received.complete();
      },
    );
    final assertion = expectLater(
      operation.timeout(const Duration(seconds: 3)),
      throwsA(isA<Cancelled>()),
    );
    await received.future.timeout(const Duration(seconds: 2));
    token.cancel();
    await assertion;
    expect(
      await File(p.join(temporary.path, 'stalled.jar.part')).exists(),
      isFalse,
    );
  });
}
