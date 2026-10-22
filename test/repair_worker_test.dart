import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/install_worker.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:free_your_launcher/ui/instance_details.dart';
import 'package:free_your_launcher/ui/theme.dart';

void busyWorker(InstallWorkerRequest request) {
  request.task.stage = 'CPU work';
  request.events.send(InstallerProgress(request.task));
  final clock = Stopwatch()..start();
  while (clock.elapsedMilliseconds < 450) {
    // Simulate archive decompression that would otherwise block Flutter frames.
  }
  request.events.send(request.instance);
}

void cancellableWorker(InstallWorkerRequest request) async {
  final control = ReceivePort();
  request.events.send(control.sendPort);
  request.task.stage = 'Waiting';
  request.events.send(InstallerProgress(request.task));
  await control.first;
  await Future<void>.delayed(const Duration(milliseconds: 30));
  control.close();
  request.events.send(const InstallerFailure('Cancelled', cancelled: true));
}

void failingWorker(InstallWorkerRequest request) {
  throw StateError('Worker failure');
}

void transferWorker(InstallWorkerRequest request) {
  request.task.downloadedBytes = 1048576;
  request.events.send(InstallerProgress(request.task));
  request.events.send(InstallerProgress(request.task));
  request.events.send(request.instance);
}

class RepairController extends LauncherController {
  final finish = Completer<void>();
  RepairController({required super.supportDirectory, required super.platform});
  @override
  Future<void> repairInstance(String id) async {
    instanceOperation = '修复版本';
    repairingInstanceId = id;
    notifyListeners();
    await finish.future;
    instanceOperation = null;
    repairingInstanceId = null;
    notifyListeners();
  }
}

void main() {
  const platform = HostPlatform('windows', 'x86_64');
  late Directory directory;
  late GameInstance instance;
  late InstallTask task;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fyl-repair-worker-');
    instance = GameInstance(
      id: 'test',
      name: 'Test',
      version: '1.21.1',
      root: directory.path,
      isolated: true,
      javaMajor: 21,
    );
    task = InstallTask(
      MinecraftVersion.fromJson({
        'id': instance.version,
        'type': 'release',
        'url': 'https://example.invalid/version.json',
        'releaseTime': '2024-01-01T00:00:00Z',
      }),
      instance.name,
      LauncherSettings(gameRoot: directory.path),
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  test('CPU-heavy repair work leaves the main event loop responsive', () async {
    var ticks = 0;
    Timer? timer;
    final result = await runInstallerWorker(
      platform,
      task,
      instance,
      CancellationToken(),
      entryPoint: busyWorker,
      onProgress: (progress) {
        progress.apply(task);
        timer ??= Timer.periodic(
          const Duration(milliseconds: 10),
          (_) => ticks++,
        );
      },
    );
    timer?.cancel();
    expect(result.id, instance.id);
    expect(task.stage, 'CPU work');
    expect(ticks, greaterThan(3));
  });

  test('cancellation reaches the worker and waits for its cleanup', () async {
    final token = CancellationToken();
    await expectLater(
      runInstallerWorker(
        platform,
        task,
        instance,
        token,
        entryPoint: cancellableWorker,
        onProgress: (_) => token.cancel(),
      ),
      throwsA(isA<Cancelled>()),
    );
  });

  test(
    'worker transfer progress updates the speed without duplicate bytes',
    () async {
      await runInstallerWorker(
        platform,
        task,
        instance,
        CancellationToken(),
        entryPoint: transferWorker,
        onProgress: (progress) => progress.apply(task),
      );
      expect(task.downloadedBytes, 1048576);
      expect(task.downloadRate.bytesPerSecond, greaterThan(0));
      expect(task.downloadRate.bytesPerSecond, lessThanOrEqualTo(4 * 1048576));
    },
  );

  test(
    'worker crashes and progress errors do not leave a pending repair',
    () async {
      await expectLater(
        runInstallerWorker(
          platform,
          task,
          instance,
          CancellationToken(),
          entryPoint: failingWorker,
          onProgress: (_) {},
        ),
        throwsA(isA<RemoteError>()),
      );
      await expectLater(
        runInstallerWorker(
          platform,
          task,
          instance,
          CancellationToken(),
          entryPoint: cancellableWorker,
          onProgress: (_) => throw StateError('Progress listener failure'),
        ),
        throwsStateError,
      );
    },
  );

  testWidgets('repair keeps version tabs and the back button usable', (
    tester,
  ) async {
    final controller = RepairController(
      supportDirectory: directory.path,
      platform: platform,
    );
    controller.instances.add(instance);
    addTearDown(controller.dispose);
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: const LauncherColors(false).material,
        home: FTheme(
          data: const LauncherColors(false).forui,
          child: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (_, _) => InstanceDetailsPage(
                controller: controller,
                instanceId: instance.id,
                onBack: () => returned = true,
                onDirty: (_) {},
                navigate: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('补全与修复文件'));
    await tester.tap(find.text('补全与修复文件'));
    await tester.pump();
    expect(controller.repairingInstanceId, instance.id);
    expect(find.text('正在修复…'), findsOneWidget);
    await tester.tap(find.text('启动设置'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('instance-field-minMemory')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('返回版本列表'));
    await tester.pump();
    expect(returned, isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.finish.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
