import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/download_rate.dart';
import 'package:free_your_launcher/ui/byte_size.dart';
import 'package:free_your_launcher/ui/download_speed.dart';

void main() {
  test('network speed automatically selects KB, MB and GB per second', () {
    expect(formatDownloadSpeed(0), '0.0 KB/s');
    expect(formatDownloadSpeed(512), '0.5 KB/s');
    expect(formatDownloadSpeed(1024), '1.0 KB/s');
    expect(formatDownloadSpeed(1024 * 1024), '1.0 MB/s');
    expect(formatDownloadSpeed(1024 * 1024 * 1024), '1.0 GB/s');
    expect(formatDownloadSpeed(double.nan), '0.0 KB/s');
  });

  test('speed measures recent transfers and expires without new bytes', () {
    var now = 0;
    final rate = DownloadRate(clock: () => now);
    now = 1000000;
    rate.add(1048576);
    expect(rate.bytesPerSecond, 1048576);
    now = 2000000;
    rate.add(1048576);
    expect(rate.bytesPerSecond, 1048576);
    now = 4500000;
    expect(rate.bytesPerSecond, closeTo(1048576 / 3, 0.001));
    now = 5000000;
    expect(rate.bytesPerSecond, 0);
  });

  test('reset excludes earlier attempts and concurrent chunks are summed', () {
    var now = 0;
    final rate = DownloadRate(clock: () => now);
    now = 1000000;
    rate.add(1048576);
    rate.reset();
    expect(rate.bytesPerSecond, 0);
    now = 2000000;
    rate.add(1024);
    rate.add(2048);
    expect(rate.bytesPerSecond, 3072);
    now = 6000000;
    expect(rate.bytesPerSecond, 0);
    rate.add(6144);
    expect(rate.bytesPerSecond, 2048);
  });

  testWidgets('speed refreshes on stalls and survives rebuilding its display', (
    tester,
  ) async {
    var now = 0;
    final rate = DownloadRate(clock: () => now);
    now = 1000000;
    rate.add(1048576);
    Widget harness() => MaterialApp(home: Scaffold(body: DownloadSpeed(rate)));
    await tester.pumpWidget(harness());
    expect(find.text('速度 1.0 MB/s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(harness());
    expect(find.text('速度 1.0 MB/s'), findsOneWidget);
    now = 4000000;
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('速度 0.0 KB/s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
