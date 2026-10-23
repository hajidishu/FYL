import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/game_window.dart';
import 'package:free_your_launcher/core/launch_progress.dart';

class WindowProcess extends Fake implements Process {
  @override
  final int pid;
  final ended = Completer<int>();
  WindowProcess(this.pid);
  @override
  Future<int> get exitCode => ended.future;
}

void main() {
  test(
    'a process and startup logs do not replace a visible game window',
    () async {
      final process = WindowProcess(12345);
      var visible = false, complete = false, checks = 0;
      final waiter = GameWindowWaiter(
        interval: const Duration(milliseconds: 5),
        probe: (pid) async {
          expect(pid, 12345);
          checks++;
          return visible;
        },
      );
      final result = waiter.wait(process).then((value) {
        complete = true;
        return value;
      });
      waiter.observe('Backend library: LWJGL version 3.3.3');
      waiter.observe(
        'Created: 1024x512x4 minecraft:textures/atlas/blocks.png-atlas',
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(complete, isFalse);
      visible = true;
      expect(await result, isTrue);
      final previous = checks;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(checks, previous);
      process.ended.complete(0);
    },
  );

  test(
    'unsupported enumeration requires evidence of a rendering context',
    () async {
      final process = WindowProcess(42);
      final waiter = GameWindowWaiter(probe: (_) async => null);
      var done = false;
      final result = waiter.wait(process).then((value) {
        done = true;
        return value;
      });
      waiter.observe('Starting Minecraft 1.21.1');
      waiter.observe('LWJGL Version: 2.9.4');
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      waiter.observe('OpenGL renderer: Mesa Intel Graphics');
      expect(await result, isTrue);
      process.ended.complete(0);
    },
  );

  test('exit, user stop, and a late probe safely finish the wait', () async {
    final exited = WindowProcess(1);
    final waiter = GameWindowWaiter(probe: (_) async => false);
    final waiting = waiter.wait(exited);
    exited.ended.complete(42);
    expect(await waiting, isFalse);
    final process = WindowProcess(2);
    final probe = Completer<bool>();
    final stopped = GameWindowWaiter(probe: (_) => probe.future);
    final result = stopped.wait(process);
    stopped.stop();
    expect(await result, isFalse);
    expect(process.ended.isCompleted, isFalse);
    probe.complete(true);
    await Future<void>.delayed(Duration.zero);
    process.ended.complete(0);
  });

  test(
    'progress reflects real stages and waiting has no fabricated percentage',
    () {
      var previous = 0.0;
      for (final phase in LaunchPhase.values) {
        final progress = LaunchProgress(phase);
        if (phase == LaunchPhase.window) {
          expect(progress.fraction, isNull);
        } else {
          expect(progress.fraction, greaterThanOrEqualTo(previous));
          previous = progress.fraction!;
        }
      }
      expect(
        const LaunchProgress(LaunchPhase.files, completed: 5, total: 10).label,
        '校验游戏文件 · 5 / 10',
      );
    },
  );
}
