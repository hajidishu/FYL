import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

List<String> parseLaunchTips(String source) {
  final value = jsonDecode(source);
  if (value is! List || value.any((item) => item is! String)) {
    throw const FormatException('启动小贴士文件应为字符串数组。');
  }
  return List.unmodifiable(
    value
        .cast<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toSet(),
  );
}

class LaunchTips {
  static const asset = 'assets/launch_tips.json';
  final AssetBundle bundle;
  final Random random;
  Future<List<String>>? _items;
  LaunchTips({AssetBundle? bundle, Random? random})
    : bundle = bundle ?? rootBundle,
      random = random ?? Random();

  Future<String?> choose() async {
    final items = await (_items ??= bundle
        .loadString(asset)
        .then(parseLaunchTips));
    return items.isEmpty ? null : items[random.nextInt(items.length)];
  }
}
