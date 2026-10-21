import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/ui/content_metadata.dart';

void main() {
  test(
    'download counts use ten-thousands and hundred-millions without overflow',
    () {
      expect(formatContentDownloads(0), '0');
      expect(formatContentDownloads(9999), '9999');
      expect(formatContentDownloads(10000), '1 万');
      expect(formatContentDownloads(79234567), '7923.46 万');
      expect(formatContentDownloads(99999999), '1 亿');
      expect(formatContentDownloads(100000000), '1 亿');
      expect(formatContentDownloads(251234567), '2.51 亿');
      expect(formatContentDownloads(399000000), '3.99 亿');
    },
  );

  test('update ages include minutes, hours, days, months and years', () {
    final now = DateTime.utc(2026, 10, 21, 12);
    String age(Duration duration) =>
        formatContentAge(now.subtract(duration), now: now);
    expect(formatContentAge(null, now: now), '更新时间未知');
    expect(age(const Duration(seconds: 45)), '刚刚更新');
    expect(age(const Duration(minutes: 3)), '3 分钟前更新');
    expect(age(const Duration(hours: 11)), '11 小时前更新');
    expect(age(const Duration(days: 5)), '5 天前更新');
    expect(age(const Duration(days: 30)), '1 个月前更新');
    expect(age(const Duration(days: 400)), '1 年前更新');
  });

  test(
    'supported versions keep gaps and sort numerically with a full count',
    () {
      expect(formatContentGameVersions([]), '支持版本未提供');
      expect(
        formatContentGameVersions(['1.9', '1.21.1', '1.9', '1.12.2']),
        'Minecraft 1.21.1 / 1.12.2 / 1.9',
      );
      expect(
        formatContentGameVersions(['1.9', '1.21.1', '1.12.2', '1.20.1']),
        'Minecraft 1.21.1 / 1.20.1 / 1.12.2 等 4 个版本',
      );
    },
  );
}
