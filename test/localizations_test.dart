import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/l10n/app_localizations.dart';
import 'package:free_your_launcher/l10n/translations.g.dart';
import 'package:free_your_launcher/ui/content_metadata.dart';

void main() {
  test(
    'all supported language catalogs have the same messages and placeholders',
    () {
      final source = translationCatalogs['zh-Hans']!;
      final placeholders = RegExp(r'\{p\d+\}');
      for (final language in launcherLanguages.keys) {
        final translated = translationCatalogs[language]!;
        expect(translated.keys.toSet(), source.keys.toSet());
        for (final entry in translated.entries) {
          expect(entry.value, isNotEmpty);
          expect(
            placeholders
                .allMatches(entry.value)
                .map((match) => match[0])
                .toSet(),
            placeholders
                .allMatches(source[entry.key]!)
                .map((match) => match[0])
                .toSet(),
            reason: '$language: ${entry.key}',
          );
        }
      }
    },
  );

  test(
    'the UI supports all six languages and keeps inserted user data unchanged',
    () {
      const play = {
        'zh-Hans': '开始游戏',
        'zh-Hant': '開始遊戲',
        'en': 'Play',
        'ru': 'Играть',
        'fr': 'Jouer',
        'de': 'Spielen',
      };
      for (final entry in play.entries) {
        final strings = AppLocalizations.forLanguage(entry.key);
        expect(strings.text('开始游戏'), entry.value);
        expect(strings.text('安装到 设置'), contains('设置'));
        expect(strings.text(r'D:\FYL\versions\设置'), r'D:\FYL\versions\设置');
      }
      expect(
        AppLocalizations.forLanguage(
          'en',
        ).text('设置保存失败：Bad state: 目标文件已存在：file.jar'),
        'Could not save settings: Target file already exists: file.jar',
      );
    },
  );

  test('language preferences survive settings serialization', () {
    for (final language in launcherLanguages.keys) {
      final settings = LauncherSettings(
        gameRoot: Directory.systemTemp.path,
        language: language,
      );
      expect(settings.copy().language, language);
      expect(
        LauncherSettings.fromJson(
          settings.toJson(),
          settings.gameRoot,
        ).language,
        language,
      );
    }
    expect(
      LauncherSettings.fromJson({
        'language': 'unsupported',
      }, Directory.systemTemp.path).language,
      'zh-Hans',
    );
  });

  test(
    'download counts use language-appropriate scales without changing Chinese behavior',
    () {
      expect(formatContentDownloads(252000000), '2.52 亿');
      expect(formatContentDownloads(252000000, language: 'zh-Hant'), '2.52 億');
      expect(formatContentDownloads(252000000, language: 'en'), '252 M');
      expect(formatContentDownloads(252000000, language: 'ru'), '252 млн');
      expect(formatContentDownloads(252000000, language: 'fr'), '252 M');
      expect(formatContentDownloads(252000000, language: 'de'), '252 Mio.');
    },
  );
}
