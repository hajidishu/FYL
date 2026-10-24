import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/game_process_priority.dart';
import 'package:free_your_launcher/core/game_process_priority_session.dart';
import 'package:free_your_launcher/core/game_window.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/l10n/app_localizations.dart';

class _GameProcess extends Fake implements Process {
  @override
  final int pid;
  final ended = Completer<int>();
  _GameProcess(this.pid);
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => ended.future;
}

class _PriorityLauncher extends LauncherController {
  final processes = <_GameProcess>[];
  _PriorityLauncher({required super.supportDirectory, required super.platform});

  @override
  Future<LaunchCommand> prepareLaunch(
    GameInstance instance,
    LauncherSettings snapshot,
    GameSession session,
  ) async => LaunchCommand('test-java', [], instance.gameDirectory);

  @override
  Future<Process> startGameProcess(LaunchCommand command) async {
    final process = _GameProcess(1000 + processes.length);
    processes.add(process);
    return process;
  }

  @override
  Future<bool> waitForGameWindow(
    RunningGame game,
    GameWindowWaiter waiter,
  ) async => true;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fyl/game_process_priority');
  final calls = <MethodCall>[];
  final sessions = <String, Map<String, dynamic>>{};

  setUp(() {
    calls.clear();
    sessions.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final id = arguments['id'] as String;
      if (call.method == 'begin') sessions[id] = arguments;
      final session = sessions[id];
      if (call.method == 'finish') sessions.remove(id);
      return {
        'processes': [
          if (session != null)
            {
              'pid': session['pid'],
              'actual': session['priority'],
              'success': true,
              'error': 0,
            },
        ],
      };
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'old settings default to normal and version overrides remain optional',
    () {
      final defaults = LauncherSettings.fromJson({}, Directory.systemTemp.path);
      expect(defaults.gameProcessPriority, GameProcessPriority.normal);
      expect(InstanceLaunchSettings.fromJson({}).gameProcessPriority, isNull);
      defaults.gameProcessPriority = GameProcessPriority.aboveNormal;
      expect(
        const InstanceLaunchSettings().apply(defaults).gameProcessPriority,
        GameProcessPriority.aboveNormal,
      );
      for (final priority in GameProcessPriority.values) {
        defaults.gameProcessPriority = priority;
        expect(defaults.copy().gameProcessPriority, priority);
        final version = InstanceLaunchSettings.fromJson(
          InstanceLaunchSettings(gameProcessPriority: priority).toJson(),
        );
        expect(version.gameProcessPriority, priority);
        expect(version.apply(defaults).gameProcessPriority, priority);
      }
      final unknown = LauncherSettings.fromJson({
        'gameProcessPriority': 'realtime',
      }, Directory.systemTemp.path);
      expect(unknown.gameProcessPriority, GameProcessPriority.normal);
      expect(
        InstanceLaunchSettings.fromJson({
          'gameProcessPriority': 'realtime',
        }).gameProcessPriority,
        isNull,
      );
    },
  );

  test(
    'simultaneous clients keep separate sessions and finish only once',
    () async {
      final logs = <String>[];
      final first = GameProcessPrioritySession(
        pid: 42,
        priority: GameProcessPriority.aboveNormal,
        onLog: logs.add,
      );
      final second = GameProcessPrioritySession(
        pid: 43,
        priority: GameProcessPriority.belowNormal,
        onLog: logs.add,
      );
      await Future.wait([first.start(), second.start(), first.start()]);
      expect(sessions.length, 2);
      expect(calls.where((call) => call.method == 'begin').length, 2);
      await Future.wait([first.finish(), first.finish(), second.finish()]);
      expect(sessions, isEmpty);
      expect(calls.where((call) => call.method == 'finish').length, 2);
      expect(
        logs.any((line) => line.contains('PID 42') && line.contains('实际 高于正常')),
        isTrue,
      );
      expect(
        logs.any((line) => line.contains('PID 43') && line.contains('实际 低于正常')),
        isTrue,
      );
    },
  );

  test(
    'readback errors are logged and still release the native session',
    () async {
      final logs = <String>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return {
          'processes': [
            {'pid': 42, 'actual': 'normal', 'success': false, 'error': 5},
          ],
        };
      });
      final session = GameProcessPrioritySession(
        pid: 42,
        priority: GameProcessPriority.high,
        onLog: logs.add,
      );
      await session.start();
      await session.finish();
      expect(
        logs.any(
          (line) => line.contains('实际 正常') && line.contains('Windows 错误 5'),
        ),
        isTrue,
      );
      expect(calls.map((call) => call.method), ['begin', 'finish']);
    },
  );

  for (final os in ['windows', 'linux']) {
    test(
      'launch applies inherited and overridden priorities only on Windows ($os)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'fyl-priority-',
        );
        final controller = _PriorityLauncher(
          supportDirectory: directory.path,
          platform: HostPlatform(os, 'x86_64'),
        );
        addTearDown(() async {
          for (final process in controller.processes) {
            if (!process.ended.isCompleted) process.ended.complete(0);
          }
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (controller.runningGames.isNotEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await controller.flush();
          controller.dispose();
          await directory.delete(recursive: true);
        });
        await controller.initialize();
        await controller.addOfflineAccount('Test_Player');
        controller.settings.gameProcessPriority =
            GameProcessPriority.aboveNormal;
        for (final (id, priority) in [
          ('inherited', null),
          ('overridden', GameProcessPriority.belowNormal),
        ]) {
          controller.instances.add(
            GameInstance(
              id: id,
              name: id,
              version: '1.21.1',
              root: directory.path,
              isolated: true,
              javaMajor: 21,
              launchSettings: InstanceLaunchSettings(
                gameProcessPriority: priority,
              ),
            ),
          );
          controller.selectedId = id;
          expect(await controller.launch(), isTrue);
        }
        final started = calls.where((call) => call.method == 'begin').toList();
        if (os == 'windows') {
          expect(started.map((call) => call.arguments['priority']), [
            'aboveNormal',
            'belowNormal',
          ]);
          expect(started.map((call) => call.arguments['pid']), [1000, 1001]);
          expect(sessions, isEmpty);
        } else {
          expect(calls, isEmpty);
        }
        expect(controller.errorMessage, isNull);
      },
    );
  }

  test('priority failure leaves game launch successful', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'begin') {
        throw PlatformException(code: 'access_denied');
      }
      return <String, dynamic>{};
    });
    final directory = await Directory.systemTemp.createTemp(
      'fyl-priority-error-',
    );
    final controller = _PriorityLauncher(
      supportDirectory: directory.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    addTearDown(() async {
      for (final process in controller.processes) {
        if (!process.ended.isCompleted) process.ended.complete(0);
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (controller.runningGames.isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await controller.flush();
      controller.dispose();
      await directory.delete(recursive: true);
    });
    await controller.initialize();
    await controller.addOfflineAccount('Test_Player');
    controller.instances.add(
      GameInstance(
        id: 'test',
        name: 'test',
        version: '1.21.1',
        root: directory.path,
        isolated: true,
        javaMajor: 21,
      ),
    );
    controller.selectedId = 'test';
    expect(await controller.launch(), isTrue);
    expect(controller.errorMessage, isNull);
    expect(
      controller.logs.any((line) => line.contains('access_denied')),
      isTrue,
    );
    expect(calls.map((call) => call.method), ['begin', 'finish']);
  });

  test('inherited priority labels translate the effective global value', () {
    for (final language in launcherLanguages.keys) {
      final translations = AppLocalizations.forLanguage(language);
      final label = translations.text('跟随全局（高于正常）');
      expect(label, contains(translations.text('高于正常')));
      if (language != 'zh-Hans') expect(label, isNot('跟随全局（高于正常）'));
    }
  });
}
