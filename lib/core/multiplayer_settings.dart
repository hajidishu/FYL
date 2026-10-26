import 'dart:convert';

/// Local preferences only. Invitations, ICE passwords and session keys never
/// belong in this model or its persisted representation.
class MultiplayerSettings {
  final String addressFamily, interfaceName;
  final List<String> stunServers;
  final int localPort, stunTimeout, connectTimeout, invitationMinutes, maxPeers;
  final bool discoverLAN, announceLAN;
  const MultiplayerSettings({
    this.addressFamily = 'both',
    this.interfaceName = '',
    this.stunServers = const ['stun:stun.cloudflare.com:3478'],
    this.localPort = 0,
    this.stunTimeout = 5,
    this.connectTimeout = 45,
    this.invitationMinutes = 10,
    this.maxPeers = 16,
    this.discoverLAN = true,
    this.announceLAN = true,
  });

  factory MultiplayerSettings.fromJson(Map<String, dynamic> json) {
    final defaults = const MultiplayerSettings().toJson();
    final data = {...defaults, ...json};
    final value = MultiplayerSettings(
      addressFamily: data['addressFamily'] as String,
      interfaceName: data['interfaceName'] as String,
      stunServers: List<String>.unmodifiable(
        (data['stunServers'] as List).cast<String>(),
      ),
      localPort: data['localPort'] as int,
      stunTimeout: data['stunTimeout'] as int,
      connectTimeout: data['connectTimeout'] as int,
      invitationMinutes: data['invitationMinutes'] as int,
      maxPeers: data['maxPeers'] as int,
      discoverLAN: data['discoverLAN'] as bool,
      announceLAN: data['announceLAN'] as bool,
    );
    value.validate();
    return value;
  }

  void validate() {
    if (!const ['both', 'ipv4', 'ipv6'].contains(addressFamily) ||
        utf8.encode(interfaceName).length > 256 ||
        interfaceName.contains(RegExp(r'[\x00-\x1f]')) ||
        localPort < 0 ||
        localPort > 65535 ||
        stunTimeout < 1 ||
        stunTimeout > 10 ||
        connectTimeout < 10 ||
        connectTimeout > 120 ||
        invitationMinutes < 1 ||
        invitationMinutes > 10 ||
        maxPeers < 1 ||
        maxPeers > 16) {
      throw const FormatException('联机设置超出允许范围，请检查输入');
    }
    if (stunServers.length > 8) {
      throw const FormatException('最多可设置 8 个 STUN 服务器');
    }
    for (final server in stunServers) {
      if (server.length > 512 ||
          !server.startsWith('stun:') ||
          server.contains(RegExp(r'\s')) ||
          server.contains(RegExp(r'[?#/@]'))) {
        throw const FormatException('STUN 地址应为 stun:主机:端口，仅支持 UDP');
      }
      final uri = Uri.tryParse('stun://${server.substring(5)}');
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
        throw const FormatException('STUN 地址应为 stun:主机:端口，仅支持 UDP');
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'addressFamily': addressFamily,
    'interfaceName': interfaceName,
    'stunServers': List<String>.of(stunServers),
    'localPort': localPort,
    'stunTimeout': stunTimeout,
    'connectTimeout': connectTimeout,
    'invitationMinutes': invitationMinutes,
    'maxPeers': maxPeers,
    'discoverLAN': discoverLAN,
    'announceLAN': announceLAN,
  };
}
