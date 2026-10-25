import 'dart:convert';

/// UI validation only; the networking helper also verifies candidates, subnet,
/// expiry, answer MAC and the peer certificate before creating a network.
class MultiplayerInvitation {
  final String text, kind;
  final DateTime expires;
  const MultiplayerInvitation._(this.text, this.kind, this.expires);

  factory MultiplayerInvitation.parse(
    String value, {
    required String kind,
    DateTime? now,
  }) {
    if (value.length > 65536) throw const FormatException('联机信息过长');
    final text = value.replaceAll(RegExp(r'\s'), '');
    if (!text.startsWith('FYL1:')) throw const FormatException('联机信息格式无效');
    try {
      final raw = base64Url.decode(base64Url.normalize(text.substring(5)));
      if (raw.length > 32768) throw const FormatException('联机信息过长');
      final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
      final candidates = json['c'] as List;
      if (json['v'] != 1 ||
          json['t'] != kind ||
          json['r'] is! String ||
          (json['r'] as String).length != 22 ||
          candidates.isEmpty ||
          candidates.length > 32 ||
          candidates.any(
            (candidate) => candidate is! String || candidate.length > 1024,
          ) ||
          json['u'] is! String ||
          json['p'] is! String ||
          json['f'] is! String ||
          json['d'] != 'minecraft-tcp' ||
          json['e'] is! int) {
        throw const FormatException('联机信息格式无效');
      }
      final expires = DateTime.fromMillisecondsSinceEpoch(
        (json['e'] as int) * 1000,
        isUtc: true,
      );
      final current = now ?? DateTime.now();
      if (!expires.isAfter(current)) {
        throw const FormatException('联机信息已过期，请重新创建');
      }
      if (expires.difference(current) > const Duration(minutes: 11)) {
        throw const FormatException('联机信息格式无效');
      }
      return MultiplayerInvitation._(text, kind, expires);
    } on FormatException catch (error) {
      if (const [
        '联机信息过长',
        '联机信息格式无效',
        '联机信息已过期，请重新创建',
      ].contains(error.message)) {
        rethrow;
      }
      throw const FormatException('联机信息格式无效');
    } catch (_) {
      throw const FormatException('联机信息格式无效');
    }
  }
}
