import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/accounts.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/main.dart';
import 'package:path/path.dart' as p;

class ClientProcess implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final result = Completer<int>();
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => result.future;
  Future<void> finish([int code = 0]) async {
    if (result.isCompleted) return;
    await output.close();
    await errors.close();
    result.complete(code);
  }

  void line(String text) => output.add(utf8.encode('$text\n'));
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class TestLauncher extends LauncherController {
  final processes = <ClientProcess>[];
  Completer<LaunchCommand>? preparation;
  bool failPreparation = false;
  TestLauncher({required super.supportDirectory, required super.platform});
  @override
  Future<LaunchCommand> prepareLaunch(
    GameInstance instance,
    LauncherSettings snapshot,
    GameSession session,
  ) async {
    if (failPreparation) throw StateError('Preparation failed');
    return preparation?.future ??
        LaunchCommand('test-java', [], instance.gameDirectory);
  }

  @override
  Future<Process> startGameProcess(LaunchCommand command) async {
    final process = ClientProcess();
    processes.add(process);
    return process;
  }
}

Future<void> waitFor(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(limit)) throw StateError('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory directory;
  late TestLauncher controller;
  late GameInstance first;
  late GameInstance second;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-multi-client-');
    controller = TestLauncher(
      supportDirectory: directory.path,
      platform: const HostPlatform('windows', 'x86_64'),
    );
    await controller.initialize();
    await controller.addOfflineAccount('Test_Player');
    first = GameInstance(
      id: 'first',
      name: 'First',
      version: '1.21.1',
      root: p.join(directory.path, '.minecraft'),
      isolated: true,
      javaMajor: 21,
    );
    second = GameInstance(
      id: 'second',
      name: 'Second',
      version: first.version,
      root: first.root,
      isolated: true,
      javaMajor: 21,
    );
    controller.instances.addAll([first, second]);
    controller.selectedId = first.id;
  });
  tearDown(() async {
    for (final process in controller.processes) {
      await process.finish();
    }
    await waitFor(() => controller.runningGames.isEmpty);
    controller.dispose();
    await directory.delete(recursive: true);
  });

  test('a second client can start while the first one remains alive', () async {
    expect(await controller.launch(), isTrue);
    final older = controller.processes.first;
    await controller.selectInstance(second);
    expect(await controller.launch(), isTrue);
    expect(controller.runningGames, hasLength(2));
    expect(controller.preparingLaunch, isFalse);
    expect(controller.isInstanceRunning(first.id), isTrue);
    expect(controller.isInstanceRunning(second.id), isTrue);
    await older.finish(1);
    await waitFor(() => controller.runningGames.length == 1);
    expect(controller.gameProcess, same(controller.processes.last));
    expect(controller.lastExitCode, isNull);
    expect(controller.isInstanceRunning(second.id), isTrue);
    expect(() => controller.editableInstance(second.id), throwsStateError);
    expect(controller.editableInstance(first.id), same(first));
  });

  test(
    'the same version can launch twice and each client owns its log',
    () async {
      await controller.launch();
      final oldLog = controller.lastLogPath!;
      await controller.launch();
      final newLog = controller.lastLogPath!;
      expect(newLog, isNot(oldLog));
      controller.processes.first.line('older client output');
      controller.processes.last.line('newer client output');
      await waitFor(() => controller.logs.contains('newer client output'));
      expect(controller.logs, isNot(contains('older client output')));
      await controller.processes.last.finish();
      await waitFor(() => controller.runningGames.length == 1);
      expect(controller.hasLiveLog, isFalse);
      expect(controller.lastExitCode, 0);
      expect(controller.isGameDirectoryInUse(first.gameDirectory), isTrue);
      await controller.processes.first.finish();
      await waitFor(() => controller.runningGames.isEmpty);
      expect(
        await File(oldLog).readAsString(),
        contains('older client output'),
      );
      expect(
        await File(newLog).readAsString(),
        contains('newer client output'),
      );
      expect(
        await File(newLog).readAsString(),
        isNot(contains('older client output')),
      );
    },
  );

  test(
    'preparation serializes launches and failures restore the ready state',
    () async {
      final gate = controller.preparation = Completer<LaunchCommand>();
      final launching = controller.launch();
      expect(controller.preparingLaunch, isTrue);
      expect(await controller.launch(), isFalse);
      gate.complete(LaunchCommand('test-java', [], first.gameDirectory));
      expect(await launching, isTrue);
      controller.preparation = null;
      controller.failPreparation = true;
      expect(await controller.launch(), isFalse);
      expect(controller.preparingLaunch, isFalse);
      expect(controller.runningGames, hasLength(1));
      controller.failPreparation = false;
      expect(await controller.launch(), isTrue);
    },
  );

  testWidgets('the home button animates during launch and can launch again', (
    tester,
  ) async {
    final gate = controller.preparation = Completer<LaunchCommand>();
    await tester.pumpWidget(
      LauncherApp(controller: controller, nativeWindow: false),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('launch-game'));
    await tester.runAsync(() async {
      await tester.tap(button);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('launch-progress')), findsOneWidget);
    expect(tester.widget<FButton>(button).onPress, isNull);
    await tester.runAsync(() async {
      gate.complete(LaunchCommand('test-java', [], first.gameDirectory));
      await waitFor(() => !controller.preparingLaunch);
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('launch-progress')), findsNothing);
    expect(find.text('游戏正在运行'), findsNothing);
    expect(tester.widget<FButton>(button).onPress, isNotNull);
    expect(controller.runningGames, hasLength(1));
    controller.preparation = null;
    await tester.runAsync(() async {
      await tester.tap(button);
      await waitFor(() => controller.processes.length == 2);
    });
    await tester.pumpAndSettle();
    expect(controller.runningGames, hasLength(2));
    expect(tester.widget<FButton>(button).onPress, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      for (final process in controller.processes) {
        await process.finish();
      }
      await waitFor(() => controller.runningGames.isEmpty);
    });
  });
}
