/// The official Log4j configuration emits XML events. Keep raw data on disk,
/// but present their messages without XML markup in the live log viewer.
class GameLogFormatter {
  String? level;
  String? thread;
  bool inCdata = false;

  String? format(String raw) {
    final text = raw.trim();
    if (text.startsWith('<log4j:Event ')) {
      level = RegExp(r'level="([^"]+)"').firstMatch(text)?.group(1);
      thread = RegExp(r'thread="([^"]+)"').firstMatch(text)?.group(1);
      return null;
    }
    final start = text.indexOf('<![CDATA[');
    if (start >= 0) {
      final content = text.substring(start + 9);
      final end = content.indexOf(']]>');
      inCdata = end < 0;
      final message = end < 0 ? content : content.substring(0, end);
      return '${level == null ? '' : '[$level] '}${thread == null ? '' : '[$thread] '}$message';
    }
    if (inCdata) {
      final end = raw.indexOf(']]>');
      if (end >= 0) {
        inCdata = false;
        return raw.substring(0, end);
      }
      return raw;
    }
    if (text.startsWith('<log4j:') || text.startsWith('</log4j:')) return null;
    return raw;
  }
}
