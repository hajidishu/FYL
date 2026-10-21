import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/game_log.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:path/path.dart' as p;

void main() {
  const win = HostPlatform('windows', 'x86_64', '10.0.26100');
  const mac = HostPlatform('osx', 'arm64');
  const linux = HostPlatform('linux', 'x86_64');
  test(
    'official XML logs become readable while preserving stack trace lines',
    () {
      final formatter = GameLogFormatter();
      expect(
        formatter.format('<log4j:Event level="INFO" thread="Render thread">'),
        isNull,
      );
      expect(
        formatter.format(
          '<log4j:Message><![CDATA[Sound engine started]]></log4j:Message>',
        ),
        '[INFO] [Render thread] Sound engine started',
      );
      expect(formatter.format('</log4j:Event>'), isNull);
      expect(
        formatter.format('<log4j:Throwable><![CDATA[java.lang.Exception: test'),
        '[INFO] [Render thread] java.lang.Exception: test',
      );
      expect(
        formatter.format('  at test.Main.main(Main.java:1)'),
        '  at test.Main.main(Main.java:1)',
      );
      expect(formatter.format(']]></log4j:Throwable>'), '');
      expect(
        formatter.format('ordinary stderr output'),
        'ordinary stderr output',
      );
    },
  );
  test('offline UUID agrees with Java nameUUIDFromBytes', () {
    expect(offlineUuid('Steve'), '5627dd98e6be3c21b8a8e92344183641');
    expect(offlineUuid('Steve'), isNot(offlineUuid('steve')));
    expect(validateUsername('Player_01'), isNull);
    expect(validateUsername('ab'), isNotNull);
    expect(validateUsername('name with spaces'), isNotNull);
  });
  test('rules use ordered matches and require a positive match', () {
    final rules = [
      {'action': 'allow'},
      {
        'action': 'disallow',
        'os': {'name': 'windows'},
      },
    ];
    expect(win.allows(rules), isFalse);
    expect(mac.allows(rules), isTrue);
    expect(
      linux.allows([
        {
          'action': 'allow',
          'os': {'name': 'osx'},
        },
      ]),
      isFalse,
    );
    expect(
      win.allows([
        {
          'action': 'allow',
          'os': {'arch': 'amd64'},
        },
      ]),
      isTrue,
    );
    expect(
      mac.allows([
        {
          'action': 'allow',
          'os': {'arch': 'aarch64'},
        },
      ]),
      isTrue,
    );
    expect(
      win.allows([
        {
          'action': 'allow',
          'os': {'version': r'^10\.'},
        },
      ]),
      isTrue,
    );
  });
  test('conditional arguments exclude demo and quick play', () {
    final args = resolveArguments(
      [
        '--username',
        r'${auth_player_name}',
        {
          'rules': [
            {
              'action': 'allow',
              'features': {'is_demo_user': true},
            },
          ],
          'value': '--demo',
        },
        {
          'rules': [
            {
              'action': 'allow',
              'features': {'has_custom_resolution': true},
            },
          ],
          'value': ['--width', r'${resolution_width}'],
        },
      ],
      win,
      {'auth_player_name': 'Test_User', 'resolution_width': '1280'},
      features: {'has_custom_resolution': true},
    );
    expect(args, ['--username', 'Test_User', '--width', '1280']);
  });
  test('library plan separates native archives and filters platforms', () {
    final root = Directory.systemTemp.path;
    final data = <String, dynamic>{
      'libraries': [
        {
          'name': 'x:client:1',
          'downloads': {
            'artifact': {
              'path': 'x/client.jar',
              'url': 'https://libraries.minecraft.net/c.jar',
            },
          },
        },
        {
          'name': 'x:mac:1',
          'rules': [
            {
              'action': 'allow',
              'os': {'name': 'osx'},
            },
          ],
          'downloads': {
            'artifact': {
              'path': 'x/mac.jar',
              'url': 'https://libraries.minecraft.net/m.jar',
            },
          },
        },
        {
          'name': 'x:native:1',
          'natives': {'windows': r'natives-windows-${arch}'},
          'downloads': {
            'classifiers': {
              'natives-windows-64': {
                'path': 'x/native.jar',
                'url': 'https://libraries.minecraft.net/n.jar',
              },
            },
          },
        },
      ],
    };
    final plan = planLibraries(data, root, win);
    expect(plan.downloads.length, 2);
    expect(plan.classpath, [p.join(root, 'libraries', 'x', 'client.jar')]);
    expect(plan.nativeArchives.single.$1, endsWith('native.jar'));
  });
  test('isolation defaults on and belongs to the instance', () {
    final root = Directory.systemTemp.path;
    final settings = LauncherSettings(gameRoot: root);
    expect(settings.isolateVersions, isTrue);
    final first = GameInstance(
      id: 'first',
      name: 'One',
      version: '1.21.1',
      root: root,
      isolated: settings.isolateVersions,
      javaMajor: 21,
    );
    settings.isolateVersions = false;
    final second = GameInstance(
      id: 'second',
      name: 'Two',
      version: '1.21.1',
      root: root,
      isolated: settings.isolateVersions,
      javaMajor: 21,
    );
    expect(first.gameDirectory, p.join(root, 'versions', 'One'));
    expect(second.gameDirectory, root);
    expect(first.metadataPath, p.join(root, 'versions', 'One', 'One.json'));
    expect(second.clientJarPath, p.join(root, 'versions', 'Two', 'Two.jar'));
    expect(GameInstance.fromJson(first.toJson()).isolated, isTrue);
  });
  test('launch command preserves spaces and applies configurable settings', () {
    final root = p.join(Directory.systemTemp.path, 'Minecraft Test');
    final instance = GameInstance(
      id: 'test',
      name: 'Test',
      version: '1.21.1',
      root: root,
      isolated: true,
      javaMajor: 21,
    );
    final settings = LauncherSettings(
      gameRoot: root,
      username: 'Test_User',
      minMemory: 1024,
      maxMemory: 4096,
      width: 1600,
      height: 900,
      jvmArguments: r'-Dtest="value with spaces" -Dpath="C:\Java Home"',
    );
    final data = <String, dynamic>{
      'mainClass': 'net.minecraft.client.main.Main',
      'type': 'release',
      'libraries': [],
      'assetIndex': {'id': '17'},
      'arguments': {
        'jvm': [
          '-cp',
          r'${classpath}',
          {
            'rules': [
              {
                'action': 'allow',
                'os': {'name': 'osx'},
              },
            ],
            'value': '-XstartOnFirstThread',
          },
        ],
        'game': [
          '--username',
          r'${auth_player_name}',
          '--gameDir',
          r'${game_directory}',
          '--uuid',
          r'${auth_uuid}',
          {
            'rules': [
              {
                'action': 'allow',
                'features': {'has_custom_resolution': true},
              },
            ],
            'value': [
              '--width',
              r'${resolution_width}',
              '--height',
              r'${resolution_height}',
            ],
          },
        ],
      },
    };
    final command = buildLaunchCommand(
      instance,
      data,
      settings,
      win,
      r'C:\Java Home\bin\java.exe',
    );
    expect(
      command.arguments,
      containsAll([
        '-Xms1024M',
        '-Xmx4096M',
        '-Dtest=value with spaces',
        r'-Dpath=C:\Java Home',
        '1600',
        '900',
      ]),
    );
    expect(command.arguments, isNot(contains('-XstartOnFirstThread')));
    expect(
      command.arguments[command.arguments.indexOf('--gameDir') + 1],
      instance.gameDirectory,
    );
    expect(command.workingDirectory, instance.gameDirectory);
    settings.fullscreen = true;
    final fullscreen = buildLaunchCommand(
      instance,
      data,
      settings,
      mac,
      '/java',
    );
    expect(
      fullscreen.arguments,
      containsAll(['--fullscreen', '-XstartOnFirstThread']),
    );
    expect(fullscreen.arguments, isNot(contains('--width')));
    expect(
      () => buildLaunchCommand(
        instance,
        data,
        settings..username = '',
        win,
        'java',
      ),
      throwsArgumentError,
    );
  });
  test('legacy launch includes classpath, natives and window dimensions', () {
    final root = Directory.systemTemp.path;
    final instance = GameInstance(
      id: 'old',
      name: 'Old',
      version: '1.12.2',
      root: root,
      isolated: true,
      javaMajor: 8,
    );
    final command = buildLaunchCommand(
      instance,
      {
        'mainClass': 'net.minecraft.client.main.Main',
        'minecraftArguments':
            r'--username ${auth_player_name} --userProperties ${user_properties}',
        'libraries': [],
      },
      LauncherSettings(gameRoot: root, username: 'Old_User'),
      linux,
      '/java',
    );
    expect(
      command.arguments,
      containsAll(['-cp', '--width', '1280', '--userProperties', '{}']),
    );
  });
  test('metadata paths cannot escape the selected root', () {
    final root = Directory.systemTemp.path;
    for (final bad in [
      '../outside',
      r'..\outside',
      '/absolute',
      r'C:\absolute',
      'inside/../../outside',
    ]) {
      expect(() => safeJoin(root, bad), throwsFormatException);
    }
    expect(
      safeJoin(root, 'inside/file.jar'),
      p.join(root, 'inside', 'file.jar'),
    );
  });
  test('Microsoft app defaults work for new and existing settings', () {
    final root = Directory.systemTemp.path;
    const defaultId = '91d04d35-a673-4844-b00b-7f3838bd2fff';
    expect(LauncherSettings(gameRoot: root).microsoftClientId, defaultId);
    for (final json in <Json>[
      {},
      {'microsoftClientId': null},
      {'microsoftClientId': ''},
      {'microsoftClientId': '   '},
    ]) {
      final settings = LauncherSettings.fromJson(json, root);
      expect(settings.microsoftClientId, defaultId);
      expect(settings.copy().microsoftClientId, defaultId);
    }
    const customId = '11111111-1111-1111-1111-111111111111';
    final custom = LauncherSettings.fromJson({
      'microsoftClientId': ' $customId ',
    }, root);
    expect(custom.copy().microsoftClientId, customId);
    expect(LauncherSettings.resolveMicrosoftClientId('  '), defaultId);
  });
  test('settings round trip and reject invalid ranges', () {
    final settings = LauncherSettings(
      gameRoot: Directory.systemTemp.path,
      isolateVersions: false,
      parallelDownloads: 12,
      theme: 'light',
    );
    final restored = LauncherSettings.fromJson(settings.toJson(), 'unused');
    expect(restored.toJson(), settings.toJson());
    expect(restored.validate(), isNull);
    restored.maxMemory = 128;
    expect(restored.validate(), isNotNull);
    expect(() => splitCommandLine('"unclosed'), throwsFormatException);
  });
  test(
    'controller persists settings, selected instance and its isolation',
    () async {
      final directory = await Directory.systemTemp.createTemp('fyl-config-');
      addTearDown(() => directory.delete(recursive: true));
      final controller = LauncherController(
        supportDirectory: directory.path,
        platform: win,
      );
      await controller.initialize();
      final instance = GameInstance(
        id: 'saved',
        name: 'Saved',
        version: '1.21.1',
        root: directory.path,
        isolated: true,
        javaMajor: 21,
      );
      controller.instances.add(instance);
      await controller.saveSettings(
        controller.settings.copy()
          ..isolateVersions = false
          ..username = 'Test_User'
          ..maxMemory = 4096,
      );
      await controller.selectInstance(instance);
      controller.dispose();
      final restored = LauncherController(
        supportDirectory: directory.path,
        platform: win,
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.settings.isolateVersions, isFalse);
      expect(restored.settings.username, 'Test_User');
      expect(restored.selectedInstance!.isolated, isTrue);
      expect(restored.selectedInstance!.id, 'saved');
    },
  );
}
