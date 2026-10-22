import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/community_catalog.dart';
import 'package:free_your_launcher/core/local_mods.dart';
import 'package:free_your_launcher/core/mod_updates.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;

class UpdateFixture {
  late Directory directory;
  late HttpServer server;
  late String base;
  late CommunityCatalog catalog;
  late ModUpdater updater;
  late GameInstance instance;
  final bytes = <String, List<int>>{};
  final requests = <String>[];
  bool curse = false,
      badDownload = false,
      dependencies = false,
      wrongLoader = false;
  bool oldUpdate = false, failLookup = false, restricted = false;

  List<int> jar(String id, int version) => ZipEncoder().encode(
    Archive()..add(
      ArchiveFile.string(
        'fabric.mod.json',
        jsonEncode({
          'id': id,
          'name': id,
          'version': '$version',
          'description': 'test mod',
        }),
      ),
    ),
  );
  Json mr(String id, int v) {
    final data = bytes['$id-$v']!;
    return {
      'id': '$id-$v',
      'project_id': id,
      'name': '$id $v',
      'version_number': '$v',
      'date_published':
          '${oldUpdate && v == 2 ? 2022 : 2023 + v}-01-01T00:00:00Z',
      'version_type': 'release',
      'game_versions': ['1.21.1'],
      'loaders': [wrongLoader && v == 2 ? 'forge' : 'fabric'],
      'files': [
        {
          'filename': '$id-$v.jar',
          'url': '$base/artifact/$id-$v',
          'hashes': {'sha1': sha1.convert(data).toString()},
          'size': data.length,
          'primary': true,
        },
      ],
      'dependencies': [
        if (dependencies && id == 'alpha' && v == 2)
          {'project_id': 'beta', 'dependency_type': 'required'},
      ],
    };
  }

  String cfProject(String id) => id == 'alpha' ? '11' : '22';
  Json cf(String id, int v) => {
    'id': (id == 'alpha' ? 100 : 200) + v,
    'modId': int.parse(cfProject(id)),
    'displayName': '$id $v',
    'fileName': '$id-$v.jar',
    'fileDate': '${2023 + v}-01-01T00:00:00Z',
    'gameVersions': ['1.21.1', 'Fabric'],
    'releaseType': 1,
    'downloadUrl': restricted && v == 2 ? null : '$base/artifact/$id-$v',
    'fileLength': bytes['$id-$v']!.length,
    'hashes': [
      {'algo': 1, 'value': sha1.convert(bytes['$id-$v']!).toString()},
    ],
    'dependencies': [],
  };

  Future<void> open({bool useCurse = false}) async {
    curse = useCurse;
    directory = await Directory.systemTemp.createTemp('fyl-mod-update-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    instance = GameInstance(
      id: 'game',
      name: 'Game',
      version: '1.21.1',
      root: directory.path,
      isolated: true,
      javaMajor: 21,
      components: 'Fabric 0.16.10',
    );
    final settings = LauncherSettings(
      gameRoot: directory.path,
      downloadRetries: 0,
      curseforgeApiKey: useCurse ? 'fixture-key' : '',
    );
    catalog = CommunityCatalog(
      settings,
      network: OfficialNetwork(
        settings,
        allowLocalhost: true,
        community: true,
        hostHeaders: {
          '127.0.0.1': {'x-api-key': 'fixture-key'},
        },
      ),
      modrinthBase: '$base/mr',
      curseforgeBase: '$base/cf',
    );
    updater = ModUpdater(catalog, directory.path);
    for (final id in ['alpha', 'beta']) {
      for (final v in [1, 2]) {
        bytes['$id-$v'] = jar(id, v);
      }
    }
    server.listen((request) async {
      final path = request.uri.path;
      requests.add(path);
      Object? response;
      if (path.startsWith('/artifact/')) {
        final data = bytes[path.split('/').last]!;
        request.response.add(badDownload ? List.filled(data.length, 0) : data);
      } else {
        request.response.headers.contentType = ContentType.json;
        final body = request.method == 'POST'
            ? jsonDecode(await utf8.decoder.bind(request).join()) as Json
            : <String, dynamic>{};
        if (path.startsWith('/mr/version_files')) {
          expect(request.method, 'POST');
          expect(body['algorithm'], 'sha1');
          if (failLookup) {
            request.response.statusCode = 503;
          } else {
            final update = path.endsWith('/update');
            if (update) {
              expect(body['game_versions'], ['1.21.1']);
              expect(body['loaders'], ['fabric']);
              expect(body['version_types'], ['release']);
            }
            response = {
              if (!curse)
                for (final id in ['alpha', 'beta'])
                  if ((body['hashes'] as List).contains(
                    sha1.convert(bytes['$id-1']!).toString(),
                  ))
                    sha1.convert(bytes['$id-1']!).toString(): mr(
                      id,
                      update ? 2 : 1,
                    ),
            };
          }
        } else if (path == '/cf/fingerprints/432') {
          expect(request.headers.value('x-api-key'), 'fixture-key');
          expect((body['fingerprints'] as List).length, greaterThan(0));
          response = {
            'data': {
              'exactMatches': [
                for (final id in ['alpha', 'beta']) {'file': cf(id, 1)},
              ],
            },
          };
        } else if (path.startsWith('/mr/project/')) {
          final id = path.split('/')[3];
          response = path.endsWith('/version')
              ? [mr(id, 2), mr(id, 1)]
              : {'id': id, 'slug': id, 'title': id, 'client_side': 'required'};
        } else if (path.startsWith('/cf/mods/')) {
          final id = path.split('/')[3] == '11' ? 'alpha' : 'beta';
          if (path.endsWith('/files')) {
            expect(request.uri.queryParameters['gameVersion'], '1.21.1');
            expect(request.uri.queryParameters['modLoaderType'], '4');
            response = {
              'data': [cf(id, 2), cf(id, 1)],
              'pagination': {'totalCount': 2},
            };
          } else {
            response = {
              'data': {
                'id': int.parse(cfProject(id)),
                'name': id,
                'links': {
                  'websiteUrl':
                      'https://www.curseforge.com/minecraft/mc-mods/$id',
                },
              },
            };
          }
        } else {
          request.response.statusCode = 404;
        }
        if (response != null) request.response.write(jsonEncode(response));
      }
      await request.response.close();
    });
  }

  Future<File> install(String id, {bool disabled = false}) async {
    final file = File(
      p.join(
        instance.gameDirectory,
        'mods',
        '$id-custom.jar${disabled ? '.disabled' : ''}',
      ),
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes['$id-1']!);
    return file;
  }

  Future<ModUpdateCheck> check() async => updater.check(
    instance,
    await scanLocalMods(instance, CancellationToken()),
    CancellationToken(),
  );
  Future<void> close() async {
    catalog.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  }
}

void main() {
  test(
    'CurseForge fingerprints match reference vectors and ignore only its whitespace bytes',
    () async {
      final root = await Directory.systemTemp.createTemp('fyl-fingerprint-');
      addTearDown(() => root.delete(recursive: true));
      for (final vector in {
        '': 1540447798,
        'a': 626045324,
        'ab': 1692487918,
        'abc': 1621425345,
        'abcd': 3376380438,
        'a b\n c\t d\r': 3376380438,
      }.entries) {
        final file = await File(
          p.join(root.path, 'mod.jar'),
        ).writeAsString(vector.key);
        final result = await fingerprintMod(file.path);
        expect(result.curse, vector.value);
        expect(result.hash, sha1.convert(utf8.encode(vector.key)).toString());
      }
    },
  );
  for (final curse in [false, true]) {
    test(
      'provider-specific checks update selected mods and preserve disabled state (curse=$curse)',
      () async {
        final f = UpdateFixture();
        await f.open(useCurse: curse);
        addTearDown(f.close);
        final alpha = await f.install('alpha', disabled: true);
        final beta = await f.install('beta');
        final check = await f.check();
        expect(check.updates, hasLength(2));
        expect(check.unidentified, 0);
        await f.updater.apply(
          f.instance,
          [check.updates[alpha.path]!],
          check,
          CancellationToken(),
        );
        expect(await alpha.exists(), isFalse);
        expect(
          await File(
            p.join(alpha.parent.path, 'alpha-2.jar.disabled'),
          ).readAsBytes(),
          f.bytes['alpha-2'],
        );
        expect(await beta.readAsBytes(), f.bytes['beta-1']);
        expect(
          await File(p.join(alpha.parent.path, 'alpha-2.jar')).exists(),
          isFalse,
        );
        final index =
            jsonDecode(
                  await File(
                    p.join(alpha.parent.path, '.fyl-managed-mods.json'),
                  ).readAsString(),
                )
                as Json;
        expect((index.values.single as Json)['path'], 'alpha-2.jar.disabled');
      },
    );
  }
  test(
    'batch updates replace every selected old filename in one transaction',
    () async {
      final f = UpdateFixture();
      await f.open();
      addTearDown(f.close);
      final alpha = await f.install('alpha');
      final beta = await f.install('beta');
      final check = await f.check();
      await f.updater.apply(
        f.instance,
        check.updates.values.toList(),
        check,
        CancellationToken(),
      );
      expect(await alpha.exists(), isFalse);
      expect(await beta.exists(), isFalse);
      expect(
        await File(p.join(alpha.parent.path, 'alpha-2.jar')).readAsBytes(),
        f.bytes['alpha-2'],
      );
      expect(
        await File(p.join(alpha.parent.path, 'beta-2.jar')).readAsBytes(),
        f.bytes['beta-2'],
      );
    },
  );
  test(
    'updating one mod resolves and replaces a required dependency without enabling it',
    () async {
      final f = UpdateFixture();
      await f.open();
      addTearDown(f.close);
      f.dependencies = true;
      final alpha = await f.install('alpha');
      final beta = await f.install('beta', disabled: true);
      final check = await f.check();
      await f.updater.apply(
        f.instance,
        [check.updates[alpha.path]!],
        check,
        CancellationToken(),
      );
      expect(await beta.exists(), isFalse);
      expect(
        await File(
          p.join(beta.parent.path, 'beta-2.jar.disabled'),
        ).readAsBytes(),
        f.bytes['beta-2'],
      );
    },
  );
  test('failed integrity leaves old mods untouched', () async {
    final f = UpdateFixture();
    await f.open();
    addTearDown(f.close);
    final alpha = await f.install('alpha');
    final check = await f.check();
    f.badDownload = true;
    await expectLater(
      f.updater.apply(
        f.instance,
        check.updates.values.toList(),
        check,
        CancellationToken(),
      ),
      throwsFormatException,
    );
    expect(await alpha.readAsBytes(), f.bytes['alpha-1']);
  });
  test(
    'cancelling a partially committed update restores mods and management index',
    () async {
      final f = UpdateFixture();
      await f.open();
      addTearDown(f.close);
      final alpha = await f.install('alpha');
      final beta = await f.install('beta');
      final index = await File(
        p.join(alpha.parent.path, '.fyl-managed-mods.json'),
      ).writeAsString('{}');
      final check = await f.check();
      final token = CancellationToken();
      await expectLater(
        f.updater.apply(
          f.instance,
          check.updates.values.toList(),
          check,
          token,
          onProgress: (stage, done, total) {
            if (stage == '应用 Mod 更新' && done == 1) token.cancel();
          },
        ),
        throwsA(isA<Cancelled>()),
      );
      expect(await alpha.readAsBytes(), f.bytes['alpha-1']);
      expect(await beta.readAsBytes(), f.bytes['beta-1']);
      expect(await index.readAsString(), '{}');
      expect(
        await File(p.join(alpha.parent.path, 'alpha-2.jar')).exists(),
        isFalse,
      );
    },
  );
  test(
    'files changed after checking are never removed or overwritten',
    () async {
      final f = UpdateFixture();
      await f.open();
      addTearDown(f.close);
      final alpha = await f.install('alpha');
      final check = await f.check();
      await alpha.writeAsString('external change');
      await expectLater(
        f.updater.apply(
          f.instance,
          check.updates.values.toList(),
          check,
          CancellationToken(),
        ),
        throwsStateError,
      );
      expect(await alpha.readAsString(), 'external change');
    },
  );
  test(
    'incompatible updates, downgrades and provider failures are not marked as updates',
    () async {
      final f = UpdateFixture();
      await f.open();
      addTearDown(f.close);
      await f.install('alpha');
      f.wrongLoader = true;
      expect((await f.check()).updates, isEmpty);
      f.wrongLoader = false;
      f.oldUpdate = true;
      expect((await f.check()).updates, isEmpty);
      f.oldUpdate = false;
      f.failLookup = true;
      final failed = await f.check();
      expect(failed.updates, isEmpty);
      expect(failed.notices.join(), contains('Modrinth'));
      expect(failed.unidentified, 1);
    },
  );
  test('restricted CurseForge updates keep the current file intact', () async {
    final f = UpdateFixture();
    await f.open(useCurse: true);
    addTearDown(f.close);
    f.restricted = true;
    final alpha = await f.install('alpha');
    final check = await f.check();
    await expectLater(
      f.updater.apply(
        f.instance,
        check.updates.values.toList(),
        check,
        CancellationToken(),
      ),
      throwsStateError,
    );
    expect(await alpha.readAsBytes(), f.bytes['alpha-1']);
  });
}
