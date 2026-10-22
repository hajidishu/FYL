import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'build_info.dart';
import 'models.dart';
import 'download_source.dart';

class Cancelled implements Exception {
  const Cancelled();
  @override
  String toString() => '任务已取消';
}

class CancellationToken {
  bool cancelled = false;
  final _callbacks = <void Function()>[];
  void cancel() {
    cancelled = true;
    for (final callback in List.of(_callbacks)) {
      callback();
    }
  }

  void check() {
    if (cancelled) throw const Cancelled();
  }

  void add(void Function() callback) {
    if (cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void remove(void Function() callback) => _callbacks.remove(callback);
}

class DownloadFile {
  final String url;
  final String path;
  final String? hash;
  final int? size;
  final Map<String, String> hashes;
  final List<String> alternativeUrls;
  final bool requireIntegrity;
  const DownloadFile(
    this.url,
    this.path, {
    this.hash,
    this.size,
    this.hashes = const {},
    this.alternativeUrls = const [],
    this.requireIntegrity = false,
  });

  Future<bool> matches(File file, {bool verify = true}) async {
    if (!await file.exists() || size != null && await file.length() != size) {
      return false;
    }
    if (!verify && !requireIntegrity) return true;
    final expected = {...hashes, 'sha1': ?hash};
    for (final entry in expected.entries) {
      final algorithm = switch (entry.key.toLowerCase()) {
        'sha1' => sha1,
        'sha512' => sha512,
        'sha256' => sha256,
        'md5' => md5,
        _ => throw FormatException('不支持的文件校验算法：${entry.key}'),
      };
      if ((await algorithm.bind(file.openRead()).first)
              .toString()
              .toLowerCase() !=
          entry.value.toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  factory DownloadFile.fromJson(Json json, String path) => DownloadFile(
    json['url'] as String,
    path,
    hash: json['sha1'] as String?,
    size: json['size'] as int?,
  );
}

class OfficialNetwork {
  final LauncherSettings settings;
  final HttpClient _client;
  final bool allowLocalhost;
  final bool community;
  final Map<String, Map<String, String>> hostHeaders;
  OfficialNetwork(
    this.settings, {
    this.allowLocalhost = false,
    this.community = false,
    this.hostHeaders = const {},
  }) : _client = HttpClient() {
    _client.connectionTimeout = Duration(seconds: settings.timeoutSeconds);
    _client.maxConnectionsPerHost = settings.parallelDownloads;
    _client.userAgent = 'free_your_launcher/$launcherVersion';
  }

  void close() => _client.close(force: true);

  Uri _uri(String url, {bool mirrorRedirect = false}) {
    final uri = Uri.parse(url);
    const hosts = [
      'piston-meta.mojang.com',
      'piston-data.mojang.com',
      'launchermeta.mojang.com',
      'launcher.mojang.com',
      'resources.download.minecraft.net',
      'libraries.minecraft.net',
      's3.amazonaws.com',
      'meta.fabricmc.net',
      'maven.fabricmc.net',
      'meta.quiltmc.org',
      'maven.quiltmc.org',
      'maven.minecraftforge.net',
      'files.minecraftforge.net',
      'maven.neoforged.net',
      'repo.maven.apache.org',
      'optifine.net',
      'www.optifine.net',
      'api.modrinth.com',
      'cdn.modrinth.com',
      'www.curseforge.com',
      'mediafilez.forgecdn.net',
      'edge.forgecdn.net',
    ];
    if (allowLocalhost && uri.host == '127.0.0.1') return uri;
    if ((uri.host == bmclMirrorHost || mirrorRedirect) &&
        isPublicMirrorRedirect(uri)) {
      return uri;
    }
    const communityHosts = [
      'api.curseforge.com',
      'api.modrinth.com',
      'cdn.modrinth.com',
      'github.com',
      'raw.githubusercontent.com',
      'objects.githubusercontent.com',
      'release-assets.githubusercontent.com',
      'gitlab.com',
      'mediafilez.forgecdn.net',
      'edge.forgecdn.net',
      'media.forgecdn.net',
    ];
    if (uri.scheme != 'https' ||
        !(hosts.contains(uri.host) ||
            community && communityHosts.contains(uri.host)) ||
        uri.userInfo.isNotEmpty) {
      throw FormatException('下载地址不属于受支持的源：${uri.host}');
    }
    return uri;
  }

  Future<(HttpClientResponse, void Function())> _get(
    String url,
    CancellationToken token, [
    int redirects = 0,
    bool mirrorRedirect = false,
  ]) async {
    token.check();
    final uri = _uri(
      sourceDownloadUri(Uri.parse(url), settings.downloadSource).toString(),
      mirrorRedirect: mirrorRedirect,
    );
    final request = await _client.getUrl(uri);
    for (final header
        in (hostHeaders[uri.host] ?? const <String, String>{}).entries) {
      request.headers.set(header.key, header.value);
    }
    request.followRedirects = false;
    void abort() => request.abort(const Cancelled());
    token.add(abort);
    try {
      final response = await request.close().timeout(
        Duration(seconds: settings.timeoutSeconds),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects >= 5) {
          throw const HttpException('下载重定向无效或次数过多');
        }
        await response.drain<void>().timeout(
          Duration(seconds: settings.timeoutSeconds),
        );
        token.remove(abort);
        return _get(
          uri.resolve(location).toString(),
          token,
          redirects + 1,
          mirrorRedirect || uri.host == bmclMirrorHost,
        );
      }
      if (response.statusCode != 200) {
        await response.drain<void>().timeout(
          Duration(seconds: settings.timeoutSeconds),
        );
        throw HttpException(
          '下载失败，HTTP ${response.statusCode}',
          uri: Uri.parse(url),
        );
      }
      // Retain the abort callback while the response body is being streamed.
      return (response, () => token.remove(abort));
    } catch (_) {
      token.remove(abort);
      rethrow;
    }
  }

  Future<Json> json(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async =>
      await jsonValue(url, expectedHash: expectedHash, token: token) as Json;

  Future<dynamic> jsonValue(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async =>
      jsonDecode(await text(url, expectedHash: expectedHash, token: token));

  Future<String> text(
    String url, {
    String? expectedHash,
    CancellationToken? token,
  }) async {
    final cancellation = token ?? CancellationToken();
    return _retry(() async {
      final (response, release) = await _get(url, cancellation);
      try {
        final bytes = <int>[];
        await for (final chunk in _body(response, cancellation)) {
          cancellation.check();
          bytes.addAll(chunk);
          if (bytes.length > 32 * 1024 * 1024) {
            throw const FormatException('元数据超过大小限制');
          }
        }
        if (expectedHash != null &&
            sha1.convert(bytes).toString() != expectedHash) {
          throw const FormatException('官方元数据校验失败');
        }
        return utf8.decode(bytes);
      } finally {
        release();
      }
    }, cancellation);
  }

  Stream<List<int>> _body(
    HttpClientResponse response,
    CancellationToken token,
  ) {
    final controller = StreamController<List<int>>();
    late StreamSubscription<List<int>> subscription;
    void cancel() {
      if (!controller.isClosed) {
        controller.addError(const Cancelled());
        unawaited(controller.close());
      }
      unawaited(subscription.cancel());
    }

    controller.onListen = () {
      subscription = response
          .timeout(Duration(seconds: settings.timeoutSeconds))
          .listen(
            controller.add,
            onError: controller.addError,
            onDone: () {
              token.remove(cancel);
              if (!controller.isClosed) unawaited(controller.close());
            },
          );
      token.add(cancel);
    };
    controller.onPause = () => subscription.pause();
    controller.onResume = () => subscription.resume();
    controller.onCancel = () {
      token.remove(cancel);
      // HttpClient may wait for a stalled peer when cancelling its subscription.
      // Release our consumer immediately; close(force: true) tears down the socket
      // once the owning install operation has finished cancelling its workers.
      unawaited(subscription.cancel());
    };
    return controller.stream;
  }

  Future<T> _retry<T>(
    Future<T> Function() operation,
    CancellationToken token, {
    int minimumRetries = 0,
  }) async {
    for (var attempt = 0; ; attempt++) {
      token.check();
      try {
        return await operation();
      } catch (_) {
        token.check();
        if (attempt >= settings.downloadRetries && attempt >= minimumRetries) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 350 * (attempt + 1)));
      }
    }
  }

  Future<void> download(
    DownloadFile item,
    CancellationToken token, {
    void Function(int)? onBytes,
    void Function(int)? onCachedBytes,
  }) async {
    final file = File(item.path);
    if (await item.matches(file, verify: settings.verifyDownloads)) {
      onCachedBytes?.call(await file.length());
      return;
    }
    await file.parent.create(recursive: true);
    var urlIndex = 0;
    final urls = [item.url, ...item.alternativeUrls];
    await _retry(
      () async {
        final partial = File('${item.path}.part');
        IOSink? sink;
        void Function()? release;
        try {
          final responseInfo = await _get(
            urls[urlIndex++ % urls.length],
            token,
          );
          final response = responseInfo.$1;
          release = responseInfo.$2;
          sink = partial.openWrite();
          var count = 0;
          await for (final chunk in _body(response, token)) {
            token.check();
            count += chunk.length;
            sink.add(chunk);
            onBytes?.call(chunk.length);
            // Flush provides back-pressure while keeping large client/runtime files off the heap.
            if (count % (1024 * 1024) < chunk.length) await sink.flush();
          }
          await sink.close();
          sink = null;
          token.check();
          if (item.size != null && count != item.size) {
            throw const FormatException('文件大小与官方清单不符');
          }
          if (!await item.matches(partial, verify: settings.verifyDownloads)) {
            throw const FormatException('文件完整性校验失败');
          }
          if (await file.exists()) await file.delete();
          await partial.rename(file.path);
        } finally {
          release?.call();
          await sink?.close();
          if (await partial.exists()) await partial.delete();
        }
      },
      token,
      minimumRetries: urls.length - 1,
    );
  }

  Future<void> downloadAll(
    List<DownloadFile> input,
    CancellationToken token, {
    void Function(int completed, int total, String path)? onProgress,
    void Function(int)? onBytes,
    void Function(int)? onCachedBytes,
  }) async {
    final files = {for (final file in input) file.path: file}.values.toList();
    var cursor = 0;
    var completed = 0;
    Object? failure;
    StackTrace? failureStack;
    Future<void> worker() async {
      while (failure == null && cursor < files.length) {
        final file = files[cursor++];
        try {
          token.check();
          await download(
            file,
            token,
            onBytes: onBytes,
            onCachedBytes: onCachedBytes,
          );
          onProgress?.call(++completed, files.length, file.path);
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
        }
      }
    }

    await Future.wait(
      List.generate(settings.parallelDownloads.clamp(1, 16), (_) => worker()),
    );
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    token.check();
  }
}
