import 'dart:isolate';

import 'accounts.dart';
import 'launch_progress.dart';
import 'minecraft.dart';
import 'models.dart';

Future<LaunchCommand> prepareGameInBackground(
  HostPlatform platform,
  GameInstance instance,
  LauncherSettings settings,
  GameSession session,
  void Function(LaunchProgress) onProgress,
) async {
  final events = ReceivePort();
  Object? progressError;
  StackTrace? progressStack;
  final subscription = events.listen((message) {
    try {
      onProgress(message as LaunchProgress);
    } catch (error, stack) {
      progressError = error;
      progressStack = stack;
    }
  });
  try {
    final command = await _prepare(
      platform,
      instance,
      settings,
      session,
      events.sendPort,
    );
    if (progressError != null) {
      Error.throwWithStackTrace(progressError!, progressStack!);
    }
    return command;
  } finally {
    await subscription.cancel();
    events.close();
  }
}

// Isolate closures capture only transferable launch data, never Flutter state.
Future<LaunchCommand> _prepare(
  HostPlatform platform,
  GameInstance instance,
  LauncherSettings settings,
  GameSession session,
  SendPort progress,
) => Isolate.run(
  () => MinecraftRunner(
    platform,
  ).prepare(instance, settings, session: session, onProgress: progress.send),
);
