import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/launch_tips.dart';

class TipsBundle extends CachingAssetBundle {
  final String source;
  int loads = 0;
  TipsBundle(this.source);
  @override
  Future<ByteData> load(String key) async {
    expect(key, LaunchTips.asset);
    loads++;
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(source)));
  }
}

class CandidateRandom implements Random {
  int index = 0;
  final ranges = <int>[];
  @override
  int nextInt(int max) {
    ranges.add(max);
    return index++ % max;
  }

  @override
  bool nextBool() => throw UnimplementedError();
  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('tips are loaded from the packaged editable JSON resource', () async {
    final tips = parseLaunchTips(await rootBundle.loadString(LaunchTips.asset));
    expect(tips, hasLength(greaterThanOrEqualTo(3)));
    expect(tips.every((tip) => tip.trim().isNotEmpty), isTrue);
  });
  test(
    'each distinct tip occupies one equally weighted random candidate',
    () async {
      final bundle = TipsBundle('["A", "B", "C", " A ", ""]');
      final random = CandidateRandom();
      final tips = LaunchTips(bundle: bundle, random: random);
      final chosen = <String?>[];
      for (var i = 0; i < 9; i++) {
        chosen.add(await tips.choose());
      }
      expect(chosen, ['A', 'B', 'C', 'A', 'B', 'C', 'A', 'B', 'C']);
      expect(random.ranges, everyElement(3));
      expect(bundle.loads, 1);
    },
  );
  test(
    'empty and malformed resources do not require a hardcoded fallback tip',
    () async {
      expect(await LaunchTips(bundle: TipsBundle('[]')).choose(), isNull);
      expect(() => parseLaunchTips('{"text": "bad"}'), throwsFormatException);
      expect(() => parseLaunchTips('[1, "A"]'), throwsFormatException);
    },
  );
}
