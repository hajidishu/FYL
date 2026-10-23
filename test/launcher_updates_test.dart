import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:free_your_launcher/core/launcher_update_install.dart';
import 'package:free_your_launcher/core/launcher_updates.dart';
import 'package:free_your_launcher/core/models.dart';

void main() {
  Json release(
    String version, {
    bool preview = false,
    bool draft = false,
    String arch = 'x64',
    String target = 'windows',
  }) => {
    'tag_name': 'v$version',
    'prerelease': preview,
    'draft': draft,
    'assets': [
      {
        'name': 'FYL-$version-$target-$arch.zip',
        'state': 'uploaded',
        'size': 123,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url':
            'https://github.com/hajidishu/FYL/releases/download/v$version/FYL-$version-$target-$arch.zip',
      },
    ],
  };
  const windows = HostPlatform('windows', 'x86_64');
  test('semantic versions compare numbers and prerelease identifiers', () {
    expect(
      LauncherVersion.parse(
        '0.1.10',
      )!.compareTo(LauncherVersion.parse('0.1.9')!),
      greaterThan(0),
    );
    expect(
      LauncherVersion.parse(
        '1.0.0-beta.10',
      )!.compareTo(LauncherVersion.parse('1.0.0-beta.2')!),
      greaterThan(0),
    );
    expect(
      LauncherVersion.parse(
        '1.0.0',
      )!.compareTo(LauncherVersion.parse('1.0.0-rc.1')!),
      greaterThan(0),
    );
    expect(LauncherVersion.parse('1.0.0-beta.01'), isNull);
    expect(LauncherVersion.parse('development'), isNull);
  });
  test(
    'stable channel honors GitHub prerelease flags without version suffixes',
    () {
      final releases = [
        release('0.1.6', preview: true),
        release('0.1.5'),
        release('0.1.7', draft: true),
      ];
      expect(
        selectLauncherRelease(
          releases,
          '0.1.4',
          windows,
          includePreviews: false,
        )!.version,
        '0.1.5',
      );
      expect(
        selectLauncherRelease(
          releases,
          '0.1.4',
          windows,
          includePreviews: true,
        )!.version,
        '0.1.6',
      );
      expect(
        selectLauncherRelease(
          releases,
          '0.1.8',
          windows,
          includePreviews: true,
        ),
        isNull,
      );
    },
  );
  test(
    'unsupported architectures offer release page without a mismatched binary',
    () {
      final selected = selectLauncherRelease(
        [release('0.2.0', arch: 'arm64')],
        '0.1.4',
        windows,
        includePreviews: false,
      )!;
      expect(selected.asset, isNull);
      final mac = selectLauncherRelease(
        [release('0.2.0', arch: 'universal', target: 'macos')],
        '0.1.4',
        const HostPlatform('osx', 'arm64'),
        includePreviews: false,
      )!;
      expect(mac.asset, isNotNull);
    },
  );

  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('fyl-update-check-'),
  );
  tearDown(() async => root.delete(recursive: true));
  Future<Json> bundle() async {
    await File(
      p.join(root.path, 'free_your_launcher.exe'),
    ).writeAsString('executable fixture');
    final bytes = utf8.encode('executable fixture');
    final manifest = <String, dynamic>{
      'schemaVersion': 1,
      'version': '0.2.0',
      'target': 'windows',
      'entrypoint': 'free_your_launcher.exe',
      'files': {
        'free_your_launcher.exe': {
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        },
      },
      'links': {},
    };
    await File(
      p.join(root.path, 'fyl-package.json'),
    ).writeAsString(jsonEncode(manifest));
    return manifest;
  }

  test(
    'bundle integrity is mandatory before executing the staged updater',
    () async {
      await bundle();
      await verifyLauncherBundle(root.path, '0.2.0', 'windows');
      await File(
        p.join(root.path, 'free_your_launcher.exe'),
      ).writeAsString('tampered');
      await expectLater(
        verifyLauncherBundle(root.path, '0.2.0', 'windows'),
        throwsFormatException,
      );
    },
  );
  test(
    'bundle manifests cannot claim ownership of portable user data',
    () async {
      final manifest = await bundle();
      (manifest['files'] as Map)['FYL-data/launcher.json'] = {
        'size': 0,
        'sha256': 'a' * 64,
      };
      await File(
        p.join(root.path, 'fyl-package.json'),
      ).writeAsString(jsonEncode(manifest));
      await expectLater(
        verifyLauncherBundle(root.path, '0.2.0', 'windows'),
        throwsFormatException,
      );
    },
  );
  test('archive paths escaping the package root are rejected', () async {
    final bytes = utf8.encode('escape');
    final archive = Archive()
      ..addFile(ArchiveFile('FYL/../../outside.txt', bytes.length, bytes));
    final file = File(p.join(root.path, 'update.zip'));
    await file.writeAsBytes(ZipEncoder().encode(archive));
    final workspace = p.join(root.path, 'workspace');
    await Directory(workspace).create();
    await expectLater(
      prepareLauncherBundle(file.path, workspace, '0.2.0', 'windows'),
      throwsFormatException,
    );
    expect(await File(p.join(root.path, 'outside.txt')).exists(), false);
  });

  test(
    'pending backup journals survive interrupted JSON replacement',
    () async {
      final file = File(p.join(root.path, 'journal.json'));
      await File(
        '${file.path}.bak',
      ).writeAsString(jsonEncode({'phase': 'applying', 'plan': 'fixture'}));
      expect((await readLauncherUpdateJournal(file))!['phase'], 'applying');
      await file.writeAsString('{broken JSON');
      expect((await readLauncherUpdateJournal(file))!['plan'], 'fixture');
    },
  );

  test(
    'completed transactions do not leave a stale applying-phase backup',
    () async {
      final file = File(p.join(root.path, 'journal.json'));
      final journal = <String, dynamic>{'phase': 'applying', 'plan': 'fixture'};
      await file.writeAsString(jsonEncode(journal));
      await File('${file.path}.bak').writeAsString(jsonEncode(journal));
      await completeLauncherUpdateJournal(file, journal);
      expect(await readLauncherUpdateJournal(file), isNull);
      expect(await File('${file.path}.bak').exists(), false);
    },
  );

  test('Linux extraction retains executable permissions', () async {
    final binary = utf8.encode('executable fixture');
    final manifest = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'version': '0.2.0',
        'target': 'linux',
        'entrypoint': 'free_your_launcher',
        'links': {},
        'files': {
          'free_your_launcher': {
            'size': binary.length,
            'sha256': sha256.convert(binary).toString(),
          },
        },
      }),
    );
    final archive = Archive()
      ..addFile(
        ArchiveFile('FYL/free_your_launcher', binary.length, binary)
          ..mode = 0x1ed,
      )
      ..addFile(
        ArchiveFile('FYL/fyl-package.json', manifest.length, manifest)
          ..mode = 0x1a4,
      );
    final compressed = GZipEncoder().encode(TarEncoder().encode(archive));
    final file = File(p.join(root.path, 'update.tar.gz'));
    await file.writeAsBytes(compressed);
    final workspace = p.join(root.path, 'workspace');
    await Directory(workspace).create();
    final payload = await prepareLauncherBundle(
      file.path,
      workspace,
      '0.2.0',
      'linux',
    );
    expect(
      (await File(p.join(payload, 'free_your_launcher')).stat()).mode & 0x49,
      0x49,
    );
  }, skip: !Platform.isLinux);
}
