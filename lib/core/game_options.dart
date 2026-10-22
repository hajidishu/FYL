import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'file_transaction.dart';
import 'network.dart';

String chineseLanguageCode(String version) {
  final release = RegExp(r'^1\.(\d+)(?:\.|$)').firstMatch(version);
  if (release != null && int.parse(release[1]!) < 11) return 'zh_CN';
  final snapshot = RegExp(r'^(\d\d)w(\d\d)').firstMatch(version);
  if (snapshot != null &&
      (int.parse(snapshot[1]!) < 16 ||
          snapshot[1] == '16' && int.parse(snapshot[2]!) < 33)) {
    return 'zh_CN';
  }
  if (RegExp(r'^[abc]\d').hasMatch(version)) return 'zh_CN';
  return 'zh_cn';
}

List<int> chineseOptionsBytes(List<int> original, String version) {
  var text = latin1.decode(original);
  const bom = '\u00ef\u00bb\u00bf';
  final prefix = text.startsWith(bom) ? bom : '';
  text = text.substring(prefix.length);
  final newline = text.contains('\r\n') ? '\r\n' : '\n';
  final lines =
      const LineSplitter()
          .convert(text)
          .where((line) => !line.startsWith('lang:'))
          .toList()
        ..add('lang:${chineseLanguageCode(version)}');
  return latin1.encode('$prefix${lines.join(newline)}$newline');
}

Future<void> setChineseGameOptions(
  File options,
  String version,
  CancellationToken token,
) async {
  token.check();
  final path = options.path;
  final temporary =
      '$path.fyl-language-${DateTime.now().microsecondsSinceEpoch}.tmp';
  try {
    await Isolate.run(() async {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        throw const FormatException('游戏选项必须是普通文件。');
      }
      final bytes = type == FileSystemEntityType.file
          ? await File(path).readAsBytes()
          : <int>[];
      await File(temporary).parent.create(recursive: true);
      await File(
        temporary,
      ).writeAsBytes(chineseOptionsBytes(bytes, version), flush: true);
    });
    await publishFiles(p.dirname(path), [(temporary, path)], token);
  } finally {
    if (await File(temporary).exists()) await File(temporary).delete();
  }
}
