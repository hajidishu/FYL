import 'dart:async';
import 'dart:isolate';

import 'minecraft.dart';
import 'models.dart';
import 'network.dart';

class InstallWorkerRequest {
  final SendPort events;
  final HostPlatform platform;
  final InstallTask task;
  final GameInstance instance;
  final List<int>? optifineBridge;
  const InstallWorkerRequest(
    this.events,
    this.platform,
    this.task,
    this.instance,
    this.optifineBridge,
  );
}

class InstallerProgress {
  final String stage, detail;
  final int completedFiles, totalFiles, downloadedBytes, cachedBytes;
  InstallerProgress(InstallTask task)
    : stage = task.stage,
      detail = task.detail,
      completedFiles = task.completedFiles,
      totalFiles = task.totalFiles,
      downloadedBytes = task.downloadedBytes,
      cachedBytes = task.cachedBytes;

  void apply(InstallTask task) {
    task.stage = stage;
    task.detail = detail;
    task.completedFiles = completedFiles;
    task.totalFiles = totalFiles;
    task.downloadedBytes = downloadedBytes;
    task.cachedBytes = cachedBytes;
  }
}

class InstallerFailure {
  final String message;
  final bool cancelled;
  const InstallerFailure(this.message, {this.cancelled = false});
}

Future<GameInstance> runInstallerWorker(
  HostPlatform platform,
  InstallTask task,
  GameInstance instance,
  CancellationToken token, {
  List<int>? optifineBridge,
  required void Function(InstallerProgress) onProgress,
  void Function(InstallWorkerRequest) entryPoint = _installVersion,
}) async {
  token.check();
  final events = ReceivePort();
  final result = Completer<GameInstance>();
  final exited = Completer<void>();
  SendPort? control;
  void cancel() => control?.send(null);
  token.add(cancel);
  try {
    await Isolate.spawn(
      entryPoint,
      InstallWorkerRequest(
        events.sendPort,
        platform,
        task,
        instance,
        optifineBridge,
      ),
      onError: events.sendPort,
      onExit: events.sendPort,
      errorsAreFatal: true,
      debugName: 'FYL game repair',
    );
    Object? progressError;
    StackTrace? progressStack;
    final subscription = events.listen((message) {
      if (message == null) {
        exited.complete();
        if (!result.isCompleted) {
          result.completeError(StateError('修复任务意外结束，请重试。'));
        }
      } else if (message is SendPort) {
        control = message;
        if (token.cancelled) cancel();
      } else if (message is InstallerProgress) {
        try {
          onProgress(message);
        } catch (error, stack) {
          progressError = error;
          progressStack = stack;
          cancel();
        }
      } else if (!result.isCompleted) {
        if (progressError != null) {
          result.completeError(progressError!, progressStack);
        } else if (message is GameInstance) {
          result.complete(message);
        } else if (message is InstallerFailure) {
          result.completeError(
            message.cancelled ? const Cancelled() : StateError(message.message),
          );
        } else if (message is List) {
          result.completeError(RemoteError('${message[0]}', '${message[1]}'));
        }
      }
    });
    try {
      return await result.future;
    } finally {
      // Cancellation is cooperative: wait for rollback and file handles to close.
      await exited.future;
      await subscription.cancel();
    }
  } finally {
    token.remove(cancel);
    events.close();
  }
}

void _installVersion(InstallWorkerRequest request) async {
  final control = ReceivePort();
  final token = CancellationToken();
  final subscription = control.listen((_) => token.cancel());
  request.events.send(control.sendPort);
  final network = OfficialNetwork(request.task.settings);
  final clock = Stopwatch()..start();
  var nextProgress = 0;
  String? stage;
  void progress() {
    if (stage != request.task.stage ||
        clock.elapsedMilliseconds >= nextProgress) {
      stage = request.task.stage;
      nextProgress = clock.elapsedMilliseconds + 100;
      request.events.send(InstallerProgress(request.task));
    }
  }

  try {
    final instance =
        await MinecraftInstaller(
          request.platform,
          network,
          optifineBridge: request.optifineBridge,
        ).install(
          request.task,
          token,
          progress,
          existingInstance: request.instance,
        );
    request.events.send(InstallerProgress(request.task));
    request.events.send(instance);
  } catch (error) {
    request.events.send(
      InstallerFailure(
        error is StateError ? error.message.toString() : '$error',
        cancelled: error is Cancelled,
      ),
    );
  } finally {
    network.close();
    await subscription.cancel();
    control.close();
  }
}
