import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'build_info.dart';
import 'data_directory.dart';
import 'download_rate.dart';
import 'launcher_update_install.dart';
import 'minecraft.dart' show writeJson;
import 'models.dart';
import 'network.dart';

class LauncherVersion implements Comparable<LauncherVersion> {
  final int major, minor, patch;
  final List<String> pre;
  const LauncherVersion(this.major, this.minor, this.patch, this.pre);
  static LauncherVersion? parse(String value) {
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    ).firstMatch(value);
    if (match == null) return null;
    final pre = match[4]?.split('.') ?? <String>[];
    if (pre.any((part) => part.isEmpty || RegExp(r'^0\d+$').hasMatch(part))) {
      return null;
    }
    final numbers = [for (var i = 1; i <= 3; i++) int.tryParse(match[i]!)];
    if (numbers.any((value) => value == null)) return null;
    return LauncherVersion(numbers[0]!, numbers[1]!, numbers[2]!, pre);
  }

  @override
  int compareTo(LauncherVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final order = pair.$1.compareTo(pair.$2);
      if (order != 0) return order;
    }
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty == other.pre.isEmpty
          ? 0
          : pre.isEmpty
          ? 1
          : -1;
    }
    for (var i = 0; i < min(pre.length, other.pre.length); i++) {
      final numeric = RegExp(r'^\d+$');
      final a = numeric.hasMatch(pre[i]) ? BigInt.parse(pre[i]) : null;
      final b = numeric.hasMatch(other.pre[i])
          ? BigInt.parse(other.pre[i])
          : null;
      final order = a != null && b != null
          ? a.compareTo(b)
          : a != null
          ? -1
          : b != null
          ? 1
          : pre[i].compareTo(other.pre[i]);
      if (order != 0) return order;
    }
    return pre.length.compareTo(other.pre.length);
  }
}

class LauncherRelease {
  final String version, tag, notes, website;
  final bool prerelease;
  final Json? asset;
  const LauncherRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.website,
    required this.prerelease,
    this.asset,
  });
  String? get digest {
    final value = asset?['digest'];
    return value is String &&
            RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(value)
        ? value.substring(7).toLowerCase()
        : null;
  }
}

LauncherRelease? selectLauncherRelease(
  List<dynamic> releases,
  String current,
  HostPlatform platform, {
  required bool includePreviews,
}) {
  final installed = LauncherVersion.parse(current);
  LauncherRelease? chosen;
  LauncherVersion? chosenVersion;
  for (final raw in releases) {
    if (raw is! Map<String, dynamic> ||
        raw['draft'] == true ||
        !includePreviews && raw['prerelease'] == true) {
      continue;
    }
    final tag = raw['tag_name'] as String? ?? '';
    final version = LauncherVersion.parse(tag);
    if (version == null ||
        !includePreviews && version.pre.isNotEmpty ||
        installed != null && version.compareTo(installed) <= 0 ||
        chosenVersion != null && version.compareTo(chosenVersion) <= 0) {
      continue;
    }
    final number = tag.startsWith('v') ? tag.substring(1) : tag;
    final target = platform.os == 'osx' ? 'macos' : platform.os;
    final architecture = platform.arch == 'x86_64' ? 'x64' : platform.arch;
    final extension = target == 'linux' ? '.tar.gz' : '.zip';
    final names = [
      'FYL-$number-$target-$architecture$extension',
      if (target == 'macos') 'FYL-$number-macos-universal.zip',
    ];
    Json? asset;
    for (final name in names) {
      asset = (raw['assets'] as List? ?? [])
          .whereType<Json>()
          .where(
            (file) =>
                file['name'] == name &&
                file['state'] == 'uploaded' &&
                (file['size'] as num? ?? 0) > 0,
          )
          .firstOrNull;
      if (asset != null) break;
    }
    chosenVersion = version;
    chosen = LauncherRelease(
      version: number,
      tag: tag,
      notes: raw['body'] as String? ?? '',
      website:
          'https://github.com/hajidishu/FYL/releases/tag/${Uri.encodeComponent(tag)}',
      prerelease: raw['prerelease'] == true || version.pre.isNotEmpty,
      asset: asset,
    );
  }
  return chosen;
}

class LauncherUpdater {
  final String supportDirectory, currentVersion;
  final bool releaseBuild;
  final String? explicitDataDirectory;
  final HostPlatform platform;
  final LauncherSettings Function() settings;
  final void Function() onChanged;
  LauncherRelease? available;
  LauncherRelease? downloadedRelease;
  bool checking = false, downloading = false, applying = false;
  bool hasTask = false, ready = false;
  String status = '', detail = '';
  String? error, _workspace, _payload;
  String? _handoffNonce;
  int bytes = 0, cachedBytes = 0;
  final rate = DownloadRate();
  CancellationToken? _token;
  CancellationToken? _checkToken;
  bool _disposed = false;
  OfficialNetwork? _network;
  LauncherUpdater({
    required this.supportDirectory,
    required this.platform,
    required this.settings,
    required this.onChanged,
    this.currentVersion = launcherVersion,
    this.releaseBuild = launcherIsRelease,
    this.explicitDataDirectory,
  });
  bool get development =>
      !releaseBuild || LauncherVersion.parse(currentVersion) == null;
  bool get busy => downloading || applying;
  double? get progress {
    final size = downloadedRelease?.asset?['size'] as num?;
    return size == null || size == 0
        ? null
        : ((bytes + cachedBytes) / size).clamp(0, 1);
  }

  Future<void> check({bool automatic = false, String? channel}) async {
    if (_disposed || checking || busy) return;
    if (automatic && (development || !settings().checkLauncherUpdates)) return;
    final selectedChannel = channel ?? settings().launcherUpdateChannel;
    final record = File(p.join(supportDirectory, 'launcher-update-check.json'));
    if (automatic) {
      try {
        final cached = jsonDecode(await record.readAsString()) as Json;
        final checked = DateTime.parse(cached['checked'] as String);
        final age = DateTime.now().toUtc().difference(checked);
        if (cached['channel'] == selectedChannel &&
            !age.isNegative &&
            age < const Duration(hours: 24)) {
          available = selectLauncherRelease(
            cached['releases'] as List,
            currentVersion,
            platform,
            includePreviews: selectedChannel == 'preview',
          );
          onChanged();
          return;
        }
      } catch (_) {
        /* A missing cache never prevents a check. */
      }
    }
    checking = true;
    error = null;
    detail = '';
    final token = _checkToken = CancellationToken();
    final network = OfficialNetwork(
      settings().copy(),
      community: true,
      hostHeaders: {
        'api.github.com': {'Accept': 'application/vnd.github+json'},
      },
    );
    _network = network;
    onChanged();
    try {
      final releases = <dynamic>[];
      for (var page = 1; page <= 10; page++) {
        final rows =
            await network.jsonValue(
                  'https://api.github.com/repos/hajidishu/FYL/releases?per_page=100&page=$page',
                  token: token,
                )
                as List;
        releases.addAll(rows);
        if (rows.length < 100) break;
      }
      available = selectLauncherRelease(
        releases,
        currentVersion,
        platform,
        includePreviews: selectedChannel == 'preview',
      );
      token.check();
      await writeJson(record, {
        'checked': DateTime.now().toUtc().toIso8601String(),
        'channel': selectedChannel,
        'releases': releases,
      });
      detail = available == null ? '当前已是最新版本' : '';
    } catch (e) {
      if (!automatic) error = '检查启动器更新失败：$e';
    } finally {
      checking = false;
      network.close();
      if (identical(_network, network)) _network = null;
      onChanged();
    }
  }

  Future<void> download() async {
    if (_disposed || busy || checking) return;
    final release = available;
    if (development) throw StateError('开发版请通过源码或发布页面更新。');
    if (release == null || release.asset == null) {
      throw StateError('没有适用于当前系统的更新包。');
    }
    if (release.digest == null) {
      throw StateError('更新包缺少 SHA-256，无法自动安装，请从发布页面下载。');
    }
    final url = Uri.parse(release.asset!['browser_download_url'] as String);
    if (url.scheme != 'https' ||
        url.host != 'github.com' ||
        !url.path.startsWith('/hajidishu/FYL/releases/download/')) {
      throw const FormatException('启动器更新地址无效。');
    }
    hasTask = true;
    downloading = true;
    ready = false;
    error = null;
    downloadedRelease = release;
    bytes = 0;
    cachedBytes = 0;
    rate.reset();
    status = '下载启动器更新';
    final token = _token = CancellationToken();
    final network = OfficialNetwork(settings().copy(), community: true);
    _network = network;
    onChanged();
    try {
      final workspace = p.join(
        supportDirectory,
        'cache',
        'launcher-updates',
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}',
      );
      _workspace = workspace;
      final archive = p.join(workspace, p.basename(url.path));
      await network.download(
        DownloadFile(
          url.toString(),
          archive,
          size: (release.asset!['size'] as num).toInt(),
          hashes: {'sha256': release.digest!},
          requireIntegrity: true,
        ),
        token,
        onBytes: (count) {
          bytes += count;
          rate.add(count);
          onChanged();
        },
        onCachedBytes: (count) {
          cachedBytes += count;
          onChanged();
        },
      );
      status = '校验并准备更新';
      onChanged();
      _payload = await prepareLauncherBundle(
        archive,
        workspace,
        release.version,
        platform.os,
      );
      token.check();
      ready = true;
      status = '更新已就绪';
    } on Cancelled {
      status = '已取消';
    } catch (e) {
      status = '更新下载失败';
      error = e.toString();
    } finally {
      downloading = false;
      network.close();
      _network = null;
      onChanged();
    }
  }

  void cancel() => _token?.cancel();
  void dismiss() {
    if (!busy) {
      hasTask = false;
      onChanged();
    }
  }

  Future<void> startHelper() async {
    if (development) throw StateError('开发版请通过源码或发布页面更新。');
    if (!ready || busy || _workspace == null || _payload == null) {
      throw StateError('请先下载启动器更新。');
    }
    final installation = launcherInstallationDirectory();
    final currentManifest = File(p.join(installation, 'fyl-package.json'));
    if (!await currentManifest.exists()) {
      throw StateError('当前程序缺少安装清单，请从发布页面手动更新。');
    }
    applying = true;
    onChanged();
    try {
      final probe = File(
        p.join(
          installation,
          '.fyl-update-probe-${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await probe.writeAsString('FYL update write check', flush: true);
      await probe.delete();
      final manifest =
          jsonDecode(
                await File(
                  p.join(_payload!, 'fyl-package.json'),
                ).readAsString(),
              )
              as Json;
      final entrypoint = safeJoin(_payload!, manifest['entrypoint'] as String);
      final nonce = List.generate(
        32,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      _handoffNonce = nonce;
      final plan = File(p.join(_workspace!, 'apply-$nonce.json'));
      await writeJson(plan, {
        'schemaVersion': 1,
        'installation': installation,
        'payload': _payload,
        'dataDirectory': supportDirectory,
        if (explicitDataDirectory != null)
          'directoryOverride': explicitDataDirectory,
        'parentPid': pid,
        'version': downloadedRelease!.version,
        'nonce': nonce,
      });
      await Process.start(
        entrypoint,
        ['--fyl-apply-update', plan.path],
        workingDirectory: _payload,
        mode: ProcessStartMode.detached,
        environment: {
          'FYL_APPLY_UPDATE': plan.path,
          'FYL_RECOVER_UPDATE': '',
          'FYL_UPDATE_READY_PLAN': '',
        },
      );
      status = '正在启动更新助手';
      onChanged();
      final helperReady = File(p.join(_workspace!, 'helper-ready-$nonce.json'));
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (true) {
        if (await helperReady.exists()) {
          final acknowledgement =
              jsonDecode(await helperReady.readAsString()) as Json;
          if (acknowledgement['nonce'] == nonce) break;
        }
        if (DateTime.now().isAfter(deadline)) {
          await abortHandoff();
          throw StateError('更新助手未能启动，请从发布页面手动更新。');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      status = '等待退出以更新';
      onChanged();
    } catch (_) {
      applying = false;
      onChanged();
      rethrow;
    }
  }

  Future<void> abortHandoff() async {
    if (_workspace != null && _handoffNonce != null) {
      await File(
        p.join(_workspace!, 'cancelled-$_handoffNonce'),
      ).writeAsString('cancelled', flush: true);
    }
    applying = false;
    onChanged();
  }

  void dispose() {
    _disposed = true;
    _checkToken?.cancel();
    _token?.cancel();
    _network?.close();
  }
}
