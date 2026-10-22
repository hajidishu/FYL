import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/game_options.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;
import 'instance_tools_test.dart' show RepairFixtureNetwork;

void main() {
  test(
    'Chinese initialization defaults on and persists the disabled choice',
    () {
      final settings = LauncherSettings.fromJson({}, '/game');
      expect(settings.autoChinese, isTrue);
      settings.autoChinese = false;
      expect(settings.copy().autoChinese, isFalse);
    },
  );

  test(
    'language update preserves bytes, BOM, line endings and other options',
    () {
      final original = utf8.encode(
        '\ufefflang:en_us\r\nresourcePacks:["中文.zip"]\r\nfov:0.5\r\nlang:fr_fr\r\n',
      );
      final result = chineseOptionsBytes(original, '1.21.1');
      expect(result.take(3), [0xef, 0xbb, 0xbf]);
      expect(
        utf8.decode(result),
        'resourcePacks:["中文.zip"]\r\nfov:0.5\r\nlang:zh_cn\r\n',
      );
      expect(chineseLanguageCode('1.10.2'), 'zh_CN');
      expect(chineseLanguageCode('16w32a'), 'zh_CN');
      expect(chineseLanguageCode('16w33a'), 'zh_cn');
      expect(chineseLanguageCode('1.11'), 'zh_cn');
    },
  );

  for (final enabled in [true, false]) {
    test(
      'fresh game initializes Chinese only when enabled ($enabled)',
      () async {
        final root = await Directory.systemTemp.createTemp('fyl-language-');
        addTearDown(() => root.delete(recursive: true));
        final settings = LauncherSettings(
          gameRoot: root.path,
          automaticJava: false,
          javaPath: 'java',
          autoChinese: enabled,
        );
        final network = RepairFixtureNetwork(settings, utf8.encode('client'));
        addTearDown(network.close);
        final task = InstallTask(
          MinecraftVersion.fromJson({
            'id': '1.21.1',
            'type': 'release',
            'url': 'https://example.test/version',
            'releaseTime': '2024-01-01T00:00:00Z',
          }),
          'Chinese Game',
          settings,
        );
        final instance = await MinecraftInstaller(
          const HostPlatform('windows', 'x86_64'),
          network,
        ).install(task, CancellationToken(), () {});
        final options = File(p.join(instance.gameDirectory, 'options.txt'));
        expect(await options.exists(), enabled);
        if (enabled) expect(await options.readAsString(), 'lang:zh_cn\n');
        await options.writeAsString('lang:en_us\nfov:0.5\n');
        settings.autoChinese = true;
        await MinecraftInstaller(
          const HostPlatform('windows', 'x86_64'),
          network,
        ).install(task, CancellationToken(), () {}, existingInstance: instance);
        expect(await options.readAsString(), 'lang:en_us\nfov:0.5\n');
      },
    );
  }
}
