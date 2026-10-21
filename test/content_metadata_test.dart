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
    'supported versions form descending ranges and preserve unsupported gaps',
    () {
      const resumed = [
        '1.16.1',
        '1.16.2',
        '1.16.3',
        '1.16.4',
        '1.16.5',
        '1.17',
        '1.17.1',
        '1.18',
        '1.18.1',
        '1.18.2',
        '1.19',
        '1.19.1',
        '1.19.2',
        '1.19.3',
        '1.19.4',
        '1.20',
        '1.20.1',
        '1.20.2',
        '1.20.3',
        '1.20.4',
        '1.20.5',
        '1.20.6',
        '1.21',
        '1.21.1',
      ];
      const releases = ['1.12.2', '1.13', '1.15.2', '1.16', ...resumed];
      expect(formatContentGameVersions([]), '暂无正式版支持信息');
      expect(
        formatContentGameVersions([
          '1.12.2',
          ...resumed.reversed,
          '1.12.2',
        ], releases: releases),
        'Minecraft 1.21.1~1.16.1,1.12.2',
      );
      expect(
        formatContentGameVersions([
          '1.20.6',
          '1.20.5',
          '1.20.3',
          '1.20.2',
        ], releases: releases),
        'Minecraft 1.20.6~1.20.5,1.20.3~1.20.2',
      );
      expect(
        formatContentGameVersions(['1.18', '1.17'], releases: releases),
        'Minecraft 1.18,1.17',
      );
      expect(
        formatContentGameVersions([
          '1.18',
          '1.17.1',
          '1.17',
        ], releases: releases),
        'Minecraft 1.18~1.17',
      );
    },
  );

  test(
    'snapshots, pre-releases and release candidates are omitted from ranges',
    () {
      const previews = [
        '24w14a',
        '1.21-pre1',
        '1.21-rc1',
        '26.1-snapshot-1',
        '1.16_combat-6',
        'b1.7.3',
        '1.14.3 - Combat Test',
      ];
      expect(formatContentGameVersions(previews), '暂无正式版支持信息');
      expect(
        formatContentGameVersions([...previews, '1.20.1', '1.20.2', '1.20.3']),
        'Minecraft 1.20.3~1.20.1',
      );
    },
  );

  test('without a manifest only consecutive patches share a range', () {
    expect(
      formatContentGameVersions(['1.21.1', '1.20.2', '1.20.1']),
      'Minecraft 1.21.1,1.20.2~1.20.1',
    );
    expect(
      formatContentGameVersions(['26.1', '26.1.1']),
      'Minecraft 26.1.1~26.1',
    );
    expect(
      formatContentGameVersions(['1.9', '1.12.2', '1.9']),
      'Minecraft 1.12.2,1.9',
    );
  });
}
