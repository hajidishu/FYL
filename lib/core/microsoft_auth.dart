import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'accounts.dart';
import 'models.dart';
import 'network.dart';

class DeviceLoginCode {
  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final int interval;
  final DateTime expiresAt;
  DeviceLoginCode.fromJson(Json json)
    : deviceCode = json['device_code'] as String,
      userCode = json['user_code'] as String,
      verificationUri = Uri.parse(json['verification_uri'] as String),
      interval = (json['interval'] as int? ?? 5).clamp(1, 60),
      expiresAt = DateTime.now().add(
        Duration(seconds: json['expires_in'] as int),
      );
}

class MicrosoftLoginResult {
  final LauncherAccount account;
  final AccountTokens tokens;
  const MicrosoftLoginResult(this.account, this.tokens);
}

class MinecraftAppRegistrationException implements Exception {
  final int statusCode;
  static final helpUri = Uri.https('aka.ms', '/AppRegInfo');
  static const message = 'Minecraft Services 拒绝了当前应用注册，暂时无法登录。请联系启动器开发者处理。';

  const MinecraftAppRegistrationException(this.statusCode);

  @override
  String toString() => message;
}

class AuthEndpoints {
  final String microsoft;
  final String xboxUser;
  final String xboxXsts;
  final String minecraft;
  const AuthEndpoints({
    this.microsoft = 'https://login.microsoftonline.com/consumers/oauth2/v2.0',
    this.xboxUser = 'https://user.auth.xboxlive.com/user/authenticate',
    this.xboxXsts = 'https://xsts.auth.xboxlive.com/xsts/authorize',
    this.minecraft = 'https://api.minecraftservices.com',
  });
}

class MicrosoftAuth {
  final AuthEndpoints endpoints;
  final HttpClient _client;
  final Future<void> Function(Duration) delay;
  MicrosoftAuth({
    this.endpoints = const AuthEndpoints(),
    HttpClient? client,
    Future<void> Function(Duration)? delay,
  }) : _client = client ?? HttpClient(),
       delay = delay ?? Future<void>.delayed {
    _client.connectionTimeout = const Duration(seconds: 20);
  }
  void close() => _client.close(force: true);

  Future<(int, Json)> _request(
    String url, {
    Json? body,
    Map<String, String>? form,
    String? bearer,
    CancellationToken? token,
  }) async {
    token?.check();
    final request = body != null || form != null
        ? await _client.postUrl(Uri.parse(url))
        : await _client.getUrl(Uri.parse(url));
    request.followRedirects = false;
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    if (form != null) {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
      );
      request.write(Uri(queryParameters: form).query);
    } else if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    void abort() => request.abort(const Cancelled());
    token?.add(abort);
    try {
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      token?.check();
      Json json;
      try {
        json = jsonDecode(text) as Json;
      } catch (_) {
        throw StateError('登录服务返回了无法识别的响应（HTTP ${response.statusCode}）。');
      }
      return (response.statusCode, json);
    } finally {
      token?.remove(abort);
    }
  }

  String _message(Json json, String fallback) {
    final xerr = json['XErr'];
    return switch (xerr) {
      2148916233 => '此微软账户尚未建立 Xbox 档案，请先在 xbox.com 登录并创建档案。',
      2148916235 => '此账户所在地区暂不支持 Xbox 服务。',
      2148916236 || 2148916237 => '此账户需要先完成年龄验证。',
      2148916238 => '此账户需要加入家庭并由家长允许 Xbox 服务。',
      _ =>
        (json['error_description'] ??
                json['errorMessage'] ??
                json['error'] ??
                fallback)
            .toString(),
    };
  }

  Future<DeviceLoginCode> begin(
    String clientId,
    CancellationToken token,
  ) async {
    if (!RegExp(
      r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
    ).hasMatch(clientId.trim())) {
      throw ArgumentError('请先在设置 → 通用中填写 FYL 的微软应用 Client ID。');
    }
    final (status, json) = await _request(
      '${endpoints.microsoft}/devicecode',
      form: {
        'client_id': clientId.trim(),
        'scope': 'XboxLive.signin offline_access',
      },
      token: token,
    );
    if (status != 200) throw StateError(_message(json, '无法发起微软登录。'));
    final code = DeviceLoginCode.fromJson(json);
    if (code.verificationUri.scheme != 'https' ||
        ![
          'microsoft.com',
          'www.microsoft.com',
          'login.microsoftonline.com',
          'login.live.com',
        ].contains(code.verificationUri.host)) {
      throw StateError('微软登录服务返回的验证页面无效。');
    }
    return code;
  }

  Future<MicrosoftLoginResult> complete(
    String clientId,
    DeviceLoginCode code,
    CancellationToken token,
  ) async {
    var interval = code.interval;
    while (DateTime.now().isBefore(code.expiresAt)) {
      token.check();
      await delay(Duration(seconds: interval));
      token.check();
      final (status, json) = await _request(
        '${endpoints.microsoft}/token',
        form: {
          'client_id': clientId,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          'device_code': code.deviceCode,
        },
        token: token,
      );
      if (status == 200) return _minecraft(clientId, json, token);
      if (json['error'] == 'authorization_pending') continue;
      if (json['error'] == 'slow_down') {
        interval += 5;
        continue;
      }
      throw StateError(_message(json, '登录已取消或验证码已过期，请重新登录。'));
    }
    throw StateError('登录验证码已过期，请重新登录。');
  }

  Future<MicrosoftLoginResult> refresh(
    AccountTokens tokens,
    CancellationToken token,
  ) async {
    final (status, json) = await _request(
      '${endpoints.microsoft}/token',
      form: {
        'client_id': tokens.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': tokens.refreshToken,
        'scope': 'XboxLive.signin offline_access',
      },
      token: token,
    );
    if (status != 200) throw StateError('微软登录已过期，请在首页重新登录该账户。');
    json['refresh_token'] ??= tokens.refreshToken;
    return _minecraft(tokens.clientId, json, token);
  }

  Future<MicrosoftLoginResult> _minecraft(
    String clientId,
    Json microsoft,
    CancellationToken token,
  ) async {
    final (userStatus, user) = await _request(
      endpoints.xboxUser,
      body: {
        'Properties': {
          'AuthMethod': 'RPS',
          'SiteName': 'user.auth.xboxlive.com',
          'RpsTicket': 'd=${microsoft['access_token']}',
        },
        'RelyingParty': 'http://auth.xboxlive.com',
        'TokenType': 'JWT',
      },
      token: token,
    );
    if (userStatus != 200) throw StateError(_message(user, '无法验证 Xbox 账户。'));
    final (xstsStatus, xsts) = await _request(
      endpoints.xboxXsts,
      body: {
        'Properties': {
          'SandboxId': 'RETAIL',
          'UserTokens': [user['Token']],
        },
        'RelyingParty': 'rp://api.minecraftservices.com/',
        'TokenType': 'JWT',
      },
      token: token,
    );
    if (xstsStatus != 200) throw StateError(_message(xsts, '无法获取 Xbox 登录凭据。'));
    final claims = (xsts['DisplayClaims']['xui'] as List).first as Json;
    final (loginStatus, login) = await _request(
      '${endpoints.minecraft}/authentication/login_with_xbox',
      body: {'identityToken': 'XBL3.0 x=${claims['uhs']};${xsts['Token']}'},
      token: token,
    );
    if (loginStatus != 200) {
      if (RegExp(
        r'^invalid app registration\b',
        caseSensitive: false,
      ).hasMatch((login['errorMessage'] ?? '').toString().trim())) {
        throw MinecraftAppRegistrationException(loginStatus);
      }
      throw StateError(
        _message(login, '无法登录 Minecraft。请检查应用的 Minecraft / Xbox 访问权限。'),
      );
    }
    final access = login['access_token'] as String;
    final (ownershipStatus, ownership) = await _request(
      '${endpoints.minecraft}/entitlements/mcstore',
      bearer: access,
      token: token,
    );
    if (ownershipStatus != 200) {
      throw StateError(_message(ownership, '无法检查 Minecraft 游戏许可。'));
    }
    if ((ownership['items'] as List<dynamic>? ?? []).isEmpty) {
      throw StateError('此微软账户没有可用的 Minecraft Java 版游戏许可。请确认已购买游戏或订阅仍然有效。');
    }
    final (profileStatus, profile) = await _request(
      '${endpoints.minecraft}/minecraft/profile',
      bearer: access,
      token: token,
    );
    if (profileStatus == 404) {
      throw StateError('此微软账户没有可用的 Minecraft Java 版档案。请确认游戏许可，并先在官网创建角色。');
    }
    if (profileStatus != 200) {
      throw StateError(_message(profile, '无法获取 Minecraft 角色。'));
    }
    final uuid = profile['id'] as String;
    String? skinUrl;
    for (final raw in profile['skins'] as List<dynamic>? ?? []) {
      final skin = raw as Json;
      if (skin['state'] == 'ACTIVE') {
        skinUrl = skin['url'] as String?;
        break;
      }
    }
    final account = LauncherAccount(
      id: 'microsoft:$uuid',
      kind: AccountKind.microsoft,
      username: profile['name'] as String,
      uuid: uuid,
      skinUrl: skinUrl,
    );
    final tokens = AccountTokens(
      refreshToken: microsoft['refresh_token'] as String,
      accessToken: access,
      expiresAt: DateTime.now().add(
        Duration(seconds: login['expires_in'] as int? ?? 86400),
      ),
      clientId: clientId,
      xuid: claims['xid']?.toString() ?? '',
    );
    return MicrosoftLoginResult(account, tokens);
  }
}
