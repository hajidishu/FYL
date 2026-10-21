import 'dart:io';

enum DownloadSource { official, bmclapi }

const bmclMirrorHost = 'bmclapi2.bangbang93.com';

extension DownloadSourceLabel on DownloadSource {
  String get label => this == DownloadSource.official ? '官方源' : 'BMCLAPI';
  String get attribution => this == DownloadSource.official
      ? 'Minecraft 官方源'
      : 'BMCLAPI · bangbang93';
}

Uri sourceDownloadUri(Uri uri, DownloadSource source) {
  if (source != DownloadSource.bmclapi ||
      uri.userInfo.isNotEmpty ||
      !['https', 'http'].contains(uri.scheme)) {
    return uri;
  }
  final path = switch (uri.host) {
    'piston-meta.mojang.com' ||
    'piston-data.mojang.com' ||
    'launchermeta.mojang.com' ||
    'launcher.mojang.com' => uri.path,
    'resources.download.minecraft.net' => '/assets${uri.path}',
    'libraries.minecraft.net' ||
    'maven.fabricmc.net' ||
    'maven.minecraftforge.net' => '/maven${uri.path}',
    'repo.maven.apache.org' when uri.path.startsWith('/maven2/') =>
      '/maven${uri.path.substring('/maven2'.length)}',
    'files.minecraftforge.net' when uri.path.startsWith('/maven/') => uri.path,
    'meta.fabricmc.net' => '/fabric-meta${uri.path}',
    'maven.neoforged.net' when uri.path.startsWith('/releases/') =>
      '/maven${uri.path.substring('/releases'.length)}',
    _ => null,
  };
  return path == null
      ? uri
      : Uri.https(
          bmclMirrorHost,
          path,
        ).replace(query: uri.hasQuery ? uri.query : null);
}

bool isPublicMirrorRedirect(Uri uri) {
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.host.isEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    return false;
  }
  final address = InternetAddress.tryParse(host);
  if (address == null) return true;
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return false;
  }
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] != 0 &&
        bytes[0] != 10 &&
        bytes[0] != 127 &&
        bytes[0] < 224 &&
        !(bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) &&
        !(bytes[0] == 192 && bytes[1] == 168) &&
        !(bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127);
  }
  if (bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255) {
    final address = InternetAddress.fromRawAddress(bytes.sublist(12)).address;
    return isPublicMirrorRedirect(Uri(scheme: 'https', host: address));
  }
  return bytes.any((byte) => byte != 0) && (bytes[0] & 0xfe) != 0xfc;
}
