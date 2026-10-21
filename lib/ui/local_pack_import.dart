import 'package:flutter/material.dart';
import '../core/community_models.dart';
import '../core/controller.dart';
import '../core/local_pack.dart';
import 'community_page.dart';

Future<bool> importLocalPack(
  BuildContext context,
  LauncherController controller,
  String path, {
  VoidCallback? onStarted,
}) async {
  if (controller.installing || controller.preparingLaunch) {
    throw StateError('请等待当前任务完成。');
  }
  controller.dismissMessage();
  final (plan, project, release) = await stageLocalPack(
    path,
    controller.supportDirectory,
  );
  if (!context.mounted) return false;
  if (controller.installing || ModalRoute.of(context)?.isCurrent == false) {
    throw StateError('请先完成当前操作。');
  }
  final choices = await showDialog<PackChoices>(
    context: context,
    builder: (_) => PackInstallDialog(
      plan: plan,
      release: release,
      isolated: controller.settings.isolateVersions,
    ),
  );
  if (choices == null || !context.mounted) return false;
  final task = await controller.content.installPack(
    project,
    release,
    plan,
    choices.name,
    isolated: choices.isolated,
    optional: choices.optional,
    onStarted: (_) => onStarted?.call(),
  );
  return task.state == ContentTaskState.completed;
}
