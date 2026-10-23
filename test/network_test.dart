import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/build_info.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/download_source.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;

// Validate the original public URL through OfficialNetwork, but send the test
// transport to loopback so these regressions never contact GitHub.
class _GitHubTestClient implements HttpClient {
  final HttpClient transport;
  final int port;
  final List<Uri> requested;
  _GitHubTestClient(this.transport, this.port, this.requested);
  @override
  set connectionTimeout(Duration? value) => transport.connectionTimeout = value;
  @override
  set maxConnectionsPerHost(int? value) =>
      transport.maxConnectionsPerHost = value;
  @override
  set userAgent(String? value) => transport.userAgent = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested.add(url);
    return transport.getUrl(
      Uri.http(
        '127.0.0.1:$port',
        '/${url.host}${url.path}',
        url.hasQuery ? url.queryParameters : null,
      ),
    );
  }

  @override
  void close({bool force = false}) => transport.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
    'launcher GitHub API and asset redirects keep HTTPS and host restrictions',
    () async {
      final payload = utf8.encode('verified FYL release fixture');
      const asset =
          'https://github.com/hajidishu/FYL/releases/download/v0.2.0/FYL-0.2.0-windows-x64.zip';
      const cdn =
          'https://release-assets.githubusercontent.com/fixture/FYL.zip?download=1';
      server.listen((request) async {
        if (request.uri.path.startsWith('/api.github.com/')) {
          expect(
            request.headers.value('Accept'),
            'application/vnd.github+json',
          );
          expect(
            request.headers.value('Authorization'),
            'Bearer fixture-github-token',
          );
          if (request.uri.path.endsWith('/redirect')) {
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(HttpHeaders.locationHeader, asset);
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write('[{"tag_name":"v0.2.0"}]');
          }
        } else {
          expect(request.headers.value('Authorization'), isNull);
          expect(request.headers.value('Accept'), isNull);
          if (request.uri.path.startsWith('/github.com/')) {
            request.response.statusCode = HttpStatus.found;
            request.response.headers.set(HttpHeaders.locationHeader, cdn);
          } else {
            expect(
              request.uri.path,
              '/release-assets.githubusercontent.com/fixture/FYL.zip',
            );
            request.response.add(payload);
          }
        }
        await request.response.close();
      });
      for (final source in DownloadSource.values) {
        final transport = HttpClient();
        final requested = <Uri>[];
        await HttpOverrides.runZoned(
          () async {
            final api = OfficialNetwork(
              network.settings.copy()
                ..downloadRetries = 0
                ..downloadSource = source,
              community: true,
              hostHeaders: {
                'api.github.com': {
                  'Accept': 'application/vnd.github+json',
                  'Authorization': 'Bearer fixture-github-token',
                },
              },
            );
            try {
              expect(
                await api.jsonValue(
                  'https://api.github.com/repos/hajidishu/FYL/releases',
                ),
                [
                  {'tag_name': 'v0.2.0'},
                ],
              );
              // API-only headers must not accompany a cross-host redirect.
              expect(
                await api.text('https://api.github.com/redirect'),
                utf8.decode(payload),
              );
              final destination = p.join(
                temporary.path,
                '${source.name}-update.zip',
              );
              await api.download(
                DownloadFile(
                  asset,
                  destination,
                  size: payload.length,
                  hashes: {'sha256': sha256.convert(payload).toString()},
                  requireIntegrity: true,
                ),
                CancellationToken(),
              );
              expect(await File(destination).readAsBytes(), payload);
              expect(requested.map((uri) => uri.host).toSet(), {
                'api.github.com',
                'github.com',
                'release-assets.githubusercontent.com',
              });
              final allowedCount = requested.length;
              for (final url in [
                'http://api.github.com/repos/hajidishu/FYL/releases',
                'https://api.github.com.example.invalid/releases',
                'https://fixture:credential@api.github.com/releases',
              ]) {
                await expectLater(api.text(url), throwsFormatException);
              }
              expect(requested.length, allowedCount);
            } finally {
              api.close();
            }
          },
          createHttpClient: (_) =>
              _GitHubTestClient(transport, server.port, requested),
        );
      }
      network.settings.downloadRetries = 0;
      await expectLater(
        network.text('https://api.github.com/repos/hajidishu/FYL/releases'),
        throwsFormatException,
      );
    },
  );
  test(
    'download verifies, reuses good cache and repairs corrupt cache',
    () async {
      final data = utf8.encode('a complete game dependency');
      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(
          request.headers.value(HttpHeaders.userAgentHeader),
          'free_your_launcher/$launcherVersion',
        );
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
      var cachedBytes = 0, transferredBytes = 0;
      await network.download(
        file,
        CancellationToken(),
        onCachedBytes: (count) => cachedBytes += count,
        onBytes: (count) => transferredBytes += count,
      );
      expect(requests, 1);
      expect(cachedBytes, data.length);
      expect(transferredBytes, 0);
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
    'JSON POST uses scoped headers and rejects redirects and unsupported hosts',
    () async {
      final api = OfficialNetwork(
        network.settings,
        allowLocalhost: true,
        hostHeaders: {
          '127.0.0.1': {'x-api-key': 'fixture-api-key'},
        },
      );
      addTearDown(api.close);
      server.listen((request) async {
        expect(request.headers.value('x-api-key'), 'fixture-api-key');
        expect(request.headers.contentType?.mimeType, 'application/json');
        expect(jsonDecode(await utf8.decoder.bind(request).join()), {
          'hashes': ['test'],
        });
        if (request.uri.path == '/redirect') {
          request.response.statusCode = HttpStatus.temporaryRedirect;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'https://example.invalid/credentials',
          );
        } else {
          request.response.write('{"ok":true}');
        }
        await request.response.close();
      });
      expect(
        await api.postJson('$base/post', {
          'hashes': ['test'],
        }, CancellationToken()),
        {'ok': true},
      );
      await expectLater(
        api.postJson('$base/redirect', {
          'hashes': ['test'],
        }, CancellationToken()),
        throwsA(isA<HttpException>()),
      );
      await expectLater(
        api.postJson('https://example.invalid/post', {}, CancellationToken()),
        throwsFormatException,
      );
    },
  );
  test(
    'JSON POST can be cancelled while waiting for the provider response',
    () async {
      final seen = Completer<void>();
      server.listen((request) {
        if (!seen.isCompleted) seen.complete();
      });
      final token = CancellationToken();
      final pending = network.postJson('$base/wait', {
        'hashes': ['test'],
      }, token);
      await seen.future;
      token.cancel();
      await expectLater(pending, throwsA(isA<Cancelled>()));
    },
  );
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
