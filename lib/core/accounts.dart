import 'minecraft.dart' show offlineUuid, validateUsername;
import 'models.dart';

enum AccountKind { offline, microsoft }

class LauncherAccount {
  final String id;
  final AccountKind kind;
  final String username;
  final String uuid;
  final String? skinUrl;
  const LauncherAccount({
    required this.id,
    required this.kind,
    required this.username,
    required this.uuid,
    this.skinUrl,
  });
  bool get online => kind == AccountKind.microsoft;
  factory LauncherAccount.offline(String username) {
    final name = username.trim();
    final error = validateUsername(name);
    if (error != null) throw ArgumentError(error);
    final uuid = offlineUuid(name);
    return LauncherAccount(
      id: 'offline:$uuid',
      kind: AccountKind.offline,
      username: name,
      uuid: uuid,
    );
  }
  factory LauncherAccount.fromJson(Json json) => LauncherAccount(
    id: json['id'] as String,
    kind: AccountKind.values.byName(json['kind'] as String),
    username: json['username'] as String,
    uuid: json['uuid'] as String,
    skinUrl: json['skinUrl'] as String?,
  );
  Json toJson() => {
    'id': id,
    'kind': kind.name,
    'username': username,
    'uuid': uuid,
    'skinUrl': skinUrl,
  };
}

class AccountTokens {
  final String refreshToken;
  final String accessToken;
  final DateTime expiresAt;
  final String clientId;
  final String xuid;
  const AccountTokens({
    required this.refreshToken,
    required this.accessToken,
    required this.expiresAt,
    required this.clientId,
    this.xuid = '',
  });
  bool get valid =>
      expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 2)));
  Json toJson() => {
    'refreshToken': refreshToken,
    'accessToken': accessToken,
    'expiresAt': expiresAt.toIso8601String(),
    'clientId': clientId,
    'xuid': xuid,
  };
  factory AccountTokens.fromJson(Json json) => AccountTokens(
    refreshToken: json['refreshToken'] as String,
    accessToken: json['accessToken'] as String,
    expiresAt: DateTime.parse(json['expiresAt'] as String),
    clientId: json['clientId'] as String,
    xuid: json['xuid'] as String? ?? '',
  );
}

abstract interface class AccountTokenStore {
  Future<AccountTokens?> read(String accountId);
  Future<void> write(String accountId, AccountTokens tokens);
  Future<void> delete(String accountId);
}

class GameSession {
  final String username;
  final String uuid;
  final String accessToken;
  final String clientId;
  final String xuid;
  final bool online;
  const GameSession({
    required this.username,
    required this.uuid,
    this.accessToken = '0',
    this.clientId = '',
    this.xuid = '',
    this.online = false,
  });
  factory GameSession.offline(String username) =>
      GameSession(username: username, uuid: offlineUuid(username));
}
