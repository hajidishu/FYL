import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'translations.g.dart';

const launcherLanguages = <String, String>{
  'zh-Hans': '简体中文',
  'zh-Hant': '繁體中文',
  'en': 'English',
  'ru': 'Русский',
  'fr': 'Français',
  'de': 'Deutsch',
};

Locale launcherLocale(String language) => switch (language) {
  'zh-Hant' => const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  'en' => const Locale('en'),
  'ru' => const Locale('ru'),
  'fr' => const Locale('fr'),
  'de' => const Locale('de'),
  _ => const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
};

class AppLocalizations {
  static const supportedLocales = <Locale>[
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale('en'),
    Locale('ru'),
    Locale('fr'),
    Locale('de'),
  ];
  static const delegate = _AppLocalizationsDelegate();
  static final _instances = <String, AppLocalizations>{};
  // Native file pickers have no BuildContext. The active app sets this value;
  // workers continue producing canonical messages and translate only on display.
  static AppLocalizations current = forLanguage('zh-Hans');
  final String language;
  final Map<String, String> _cache = {};
  late final _patterns =
      translationCatalogs['zh-Hans']!.keys
          .where((key) => key.contains(RegExp(r'\{p\d+\}')))
          .map(_MessagePattern.new)
          .toList()
        ..sort((a, b) => b.specificity.compareTo(a.specificity));
  AppLocalizations._(this.language);
  static AppLocalizations forLanguage(String language) =>
      _instances.putIfAbsent(
        launcherLanguages.containsKey(language) ? language : 'zh-Hans',
        () => AppLocalizations._(
          launcherLanguages.containsKey(language) ? language : 'zh-Hans',
        ),
      );
  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      forLanguage('zh-Hans');

  String text(String message) => _translate(message, 0);
  String? textOrNull(String? message) => message == null ? null : text(message);
  String _translate(String message, int depth) {
    if (language == 'zh-Hans' || message.isEmpty || depth > 4) return message;
    final cached = _cache[message];
    if (cached != null) return cached;
    final messages = translationCatalogs[language]!;
    String? result = messages[message];
    if (result == null) {
      for (final prefix in [
        'Bad state: ',
        'Invalid argument(s): ',
        'FormatException: ',
      ]) {
        if (message.startsWith(prefix)) {
          result = _translate(message.substring(prefix.length), depth + 1);
          break;
        }
      }
    }
    if (result == null && RegExp(r'[\u3400-\u9fff]').hasMatch(message)) {
      for (final pattern in _patterns) {
        final match = pattern.match(message);
        if (match == null) continue;
        final template = messages[pattern.key]!;
        final nested = translatedArguments[pattern.key] ?? const <int>[];
        result = template.replaceAllMapped(RegExp(r'\{p(\d+)\}'), (token) {
          final position = int.parse(token[1]!);
          final value = match.namedGroup('p$position') ?? '';
          return nested.contains(position)
              ? _translate(value, depth + 1)
              : value;
        });
        break;
      }
    }
    // Phase progress and technical error details can append an untranslated
    // counter/line. Keep the raw detail while translating its UI heading.
    if (result == null && message.contains('\n')) {
      result = message
          .split('\n')
          .map((part) => _translate(part, depth + 1))
          .join('\n');
    }
    if (result == null && message.contains(' · ')) {
      result = message
          .split(' · ')
          .map((part) => _translate(part, depth + 1))
          .join(' · ');
    }
    result ??= message;
    if (_cache.length >= 2048) _cache.clear();
    _cache[message] = result;
    return result;
  }
}

class _MessagePattern {
  final String key;
  late final int specificity = key.replaceAll(RegExp(r'\{p\d+\}'), '').length;
  late final RegExp expression = _expression();
  late final String prefix = key.split(RegExp(r'\{p\d+\}')).first;
  late final String suffix = key.split(RegExp(r'\{p\d+\}')).last;
  _MessagePattern(this.key);
  RegExpMatch? match(String message) {
    if (prefix.isNotEmpty && !message.startsWith(prefix) ||
        suffix.isNotEmpty && !message.endsWith(suffix)) {
      return null;
    }
    return expression.firstMatch(message);
  }

  RegExp _expression() {
    final buffer = StringBuffer('^');
    var position = 0;
    for (final match in RegExp(r'\{p(\d+)\}').allMatches(key)) {
      buffer.write(RegExp.escape(key.substring(position, match.start)));
      buffer.write('(?<p${match[1]}>[\\s\\S]*?)');
      position = match.end;
    }
    buffer.write(RegExp.escape(key.substring(position)));
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) =>
      const ['zh', 'en', 'ru', 'fr', 'de'].contains(locale.languageCode);
  @override
  Future<AppLocalizations> load(Locale locale) => SynchronousFuture(
    AppLocalizations.forLanguage(
      locale.languageCode == 'zh'
          ? locale.scriptCode == 'Hant' ||
                    const ['TW', 'HK', 'MO'].contains(locale.countryCode)
                ? 'zh-Hant'
                : 'zh-Hans'
          : locale.languageCode,
    ),
  );
  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

/// For native dialogs and accessibility strings outside a widget builder.
String tr(String message) => AppLocalizations.current.text(message);
String? trNullable(String? message) => message == null ? null : tr(message);

/// Only launcher-owned UI messages use this widget. Project summaries, user
/// names, file paths and raw game output continue to use Flutter's Text.
class LText extends StatelessWidget {
  final String message;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  const LText(
    this.message, {
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Text(
    AppLocalizations.of(context).text(message),
    style: style,
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
    softWrap: softWrap,
  );
}

class LSelectableText extends StatelessWidget {
  final String message;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines, minLines;
  const LSelectableText(
    this.message, {
    this.style,
    this.textAlign,
    this.maxLines,
    this.minLines,
    super.key,
  });
  @override
  Widget build(BuildContext context) => SelectableText(
    AppLocalizations.of(context).text(message),
    style: style,
    textAlign: textAlign,
    maxLines: maxLines,
    minLines: minLines,
  );
}

class LTooltip extends StatelessWidget {
  final String message;
  final Widget child;
  final BoxConstraints? constraints;
  final Duration? waitDuration;
  const LTooltip({
    required this.message,
    required this.child,
    this.constraints,
    this.waitDuration,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Tooltip(
    message: AppLocalizations.of(context).text(message),
    constraints: constraints,
    waitDuration: waitDuration,
    child: child,
  );
}
