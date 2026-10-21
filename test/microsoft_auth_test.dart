import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/microsoft_auth.dart';
import 'package:free_your_launcher/core/network.dart';

void main() {
  late HttpServer server;
  late MicrosoftAuth auth;
  late String base;
  var polls = 0;
  var profileStatus = 200;
  var ownsGame = true;
  var minecraftLoginStatus = 200;
  var minecraftLoginError = '';
  final requests = <String>[];
  setUp(() async {
    polls = 0;
    profileStatus = 200;
    ownsGame = true;
    minecraftLoginStatus = 200;
    minecraftLoginError = '';
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    auth = MicrosoftAuth(
      endpoints: AuthEndpoints(
        microsoft: '$base/oauth',
        xboxUser: '$base/xbox',
        xboxXsts: '$base/xsts',
        minecraft: '$base/mc',
      ),
      delay: (_) async {},
    );
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final path = request.uri.path;
      requests.add(path);
      Object data;
      if (path == '/oauth/devicecode') {
        final form = Uri.splitQueryString(body);
        expect(form['scope'], 'XboxLive.signin offline_access');
        data = {
          'device_code': 'private-device-code',
          'user_code': 'ABCD1234',
          'verification_uri': 'https://www.microsoft.com/link',
          'expires_in': 600,
          'interval': 1,
        };
      } else if (path == '/oauth/token') {
        final form = Uri.splitQueryString(body);
        if (form['grant_type'] == 'refresh_token') {
          expect(form['refresh_token'], 'old-refresh');
          data = {'access_token': 'msa-access', 'refresh_token': 'new-refresh'};
        } else if (polls++ == 0) {
          request.response.statusCode = 400;
          data = {'error': 'authorization_pending'};
        } else {
          data = {'access_token': 'msa-access', 'refresh_token': 'new-refresh'};
        }
      } else if (path == '/xbox') {
        expect(jsonDecode(body)['Properties']['RpsTicket'], 'd=msa-access');
        data = {'Token': 'xbox-token'};
      } else if (path == '/xsts') {
        data = {
          'Token': 'xsts-token',
          'DisplayClaims': {
            'xui': [
              {'uhs': 'user-hash', 'xid': '100'},
            ],
          },
        };
      } else if (path == '/mc/authentication/login_with_xbox') {
        expect(
          jsonDecode(body)['identityToken'],
          'XBL3.0 x=user-hash;xsts-token',
        );
        request.response.statusCode = minecraftLoginStatus;
        data = minecraftLoginStatus == 200
            ? {'access_token': 'mc-access', 'expires_in': 3600}
            : {'errorMessage': minecraftLoginError};
      } else if (path == '/mc/entitlements/mcstore') {
        expect(request.headers.value('authorization'), 'Bearer mc-access');
        data = {
          'items': [
            if (ownsGame) {'name': 'game_minecraft'},
          ],
        };
      } else if (path == '/mc/minecraft/profile') {
        request.response.statusCode = profileStatus;
        data = profileStatus == 200
            ? {
                'id': '12345678901234567890123456789012',
                'name': 'Real_Player',
                'skins': [
                  {
                    'state': 'ACTIVE',
                    'url': 'https://textures.minecraft.net/texture/example',
                  },
                ],
              }
            : {'error': 'NOT_FOUND'};
      } else {
        request.response.statusCode = 404;
        data = {'error': 'not found'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(data));
      await request.response.close();
    });
  });
  tearDown(() async {
    auth.close();
    await server.close(force: true);
  });
  const clientId = '11111111-1111-1111-1111-111111111111';
  test(
    'device login waits for consent, validates Xbox and retrieves licensed profile',
    () async {
      final token = CancellationToken();
      final code = await auth.begin(clientId, token);
      expect(code.userCode, 'ABCD1234');
      final result = await auth.complete(clientId, code, token);
      expect(result.account.online, isTrue);
      expect(result.account.username, 'Real_Player');
      expect(
        result.account.skinUrl,
        'https://textures.minecraft.net/texture/example',
      );
      expect(result.tokens.accessToken, 'mc-access');
      expect(result.tokens.refreshToken, 'new-refresh');
      expect(result.tokens.valid, isTrue);
      expect(result.tokens.xuid, '100');
      expect(polls, 2);
      expect(
        requests,
        containsAll([
          '/xbox',
          '/xsts',
          '/mc/entitlements/mcstore',
          '/mc/minecraft/profile',
        ]),
      );
    },
  );
  test(
    'expired Microsoft token refreshes through the complete ownership chain',
    () async {
      final result = await auth.refresh(
        AccountTokens(
          refreshToken: 'old-refresh',
          accessToken: 'old-access',
          expiresAt: DateTime.fromMillisecondsSinceEpoch(0),
          clientId: clientId,
        ),
        CancellationToken(),
      );
      expect(result.tokens.refreshToken, 'new-refresh');
      expect(result.account.username, 'Real_Player');
    },
  );
  test(
    'Minecraft registration rejection stops before ownership checks',
    () async {
      minecraftLoginStatus = 403;
      minecraftLoginError =
          'Invalid app registration, see https://aka.ms/AppRegInfo for more information';
      final token = CancellationToken();
      final code = await auth.begin(clientId, token);
      await expectLater(
        auth.complete(clientId, code, token),
        throwsA(
          isA<MinecraftAppRegistrationException>()
              .having((error) => error.statusCode, 'HTTP status', 403)
              .having(
                (error) => error.toString(),
                'display message',
                contains('Minecraft Services'),
              ),
        ),
      );
      expect(requests, containsAll(['/xbox', '/xsts']));
      expect(requests, isNot(contains('/mc/entitlements/mcstore')));
      expect(requests, isNot(contains('/mc/minecraft/profile')));
    },
  );
  test(
    'registration revoked during refresh is reported the same way',
    () async {
      minecraftLoginStatus = 403;
      minecraftLoginError = 'Invalid app registration';
      await expectLater(
        auth.refresh(
          AccountTokens(
            refreshToken: 'old-refresh',
            accessToken: 'old-access',
            expiresAt: DateTime.fromMillisecondsSinceEpoch(0),
            clientId: clientId,
          ),
          CancellationToken(),
        ),
        throwsA(isA<MinecraftAppRegistrationException>()),
      );
      expect(requests, isNot(contains('/mc/entitlements/mcstore')));
    },
  );
  test('other Minecraft errors retain their service explanation', () async {
    minecraftLoginStatus = 403;
    minecraftLoginError = 'Service temporarily unavailable';
    final token = CancellationToken();
    final code = await auth.begin(clientId, token);
    await expectLater(
      auth.complete(clientId, code, token),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          minecraftLoginError,
        ),
      ),
    );
  });
  test('no Java entitlement is not treated as a licensed account', () async {
    ownsGame = false;
    final token = CancellationToken();
    final code = await auth.begin(clientId, token);
    await expectLater(
      auth.complete(clientId, code, token),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('游戏许可'),
        ),
      ),
    );
    expect(requests, isNot(contains('/mc/minecraft/profile')));
  });
  test('missing Java profile produces an actionable ownership error', () async {
    profileStatus = 404;
    final token = CancellationToken();
    final code = await auth.begin(clientId, token);
    await expectLater(
      auth.complete(clientId, code, token),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Java'),
        ),
      ),
    );
  });
  test(
    'no Client ID and cancelled sign-in cannot begin a network login',
    () async {
      await expectLater(
        auth.begin('', CancellationToken()),
        throwsArgumentError,
      );
      final token = CancellationToken()..cancel();
      await expectLater(auth.begin(clientId, token), throwsA(isA<Cancelled>()));
      expect(requests, isEmpty);
    },
  );
}
