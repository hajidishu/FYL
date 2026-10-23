import 'dart:async';

import 'package:flutter/material.dart';

import '../core/memory_allocation.dart';
import '../core/models.dart';
import '../core/system_memory.dart';
import 'theme.dart';

class MemoryPreview extends StatefulWidget {
  final LauncherSettings settings;
  final HostPlatform platform;
  final GameInstance? instance;
  final MemoryProbe probe;
  const MemoryPreview({
    required this.settings,
    required this.platform,
    this.instance,
    this.probe = readSystemMemory,
    super.key,
  });

  @override
  State<MemoryPreview> createState() => _MemoryPreviewState();
}

class _MemoryPreviewState extends State<MemoryPreview> {
  Timer? timer;
  int request = 0;
  bool loading = false;
  String? message;
  late String fingerprint;
  String get currentFingerprint =>
      '${widget.settings.automaticMemory}:'
      '${widget.settings.minMemory}:${widget.settings.maxMemory}:'
      '${widget.settings.autoMemoryLimit}:${widget.settings.jvmArguments}:${widget.instance?.id}';

  @override
  void initState() {
    super.initState();
    fingerprint = currentFingerprint;
    unawaited(refresh());
    timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!loading && widget.settings.automaticMemory) unawaited(refresh());
    });
  }

  @override
  void didUpdateWidget(MemoryPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (fingerprint != currentFingerprint) {
      fingerprint = currentFingerprint;
      unawaited(refresh());
    }
  }

  Future<void> refresh() async {
    final generation = ++request;
    loading = true;
    String text;
    try {
      final settings = widget.settings.copy();
      final error = settings.validate();
      if (error != null) throw StateError(error);
      final plan = await resolveMemoryAllocation(
        settings,
        widget.platform,
        instance: widget.instance,
        probe: widget.probe,
      );
      text =
          '${plan.automatic ? '预计' : ''}最大内存 ${plan.maximumMiB} MB'
          '${plan.system == null
              ? plan.automatic
                    ? ' · 无法读取系统内存，使用保守估算'
                    : ''
              : ' · 当前可用 ${plan.system!.availableMiB} MB'}';
    } catch (error) {
      text = error is StateError ? error.message.toString() : '暂时无法估算内存';
    }
    if (mounted && generation == request) {
      setState(() {
        message = text;
        loading = false;
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    request++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      message ?? '正在估算内存…',
      style: TextStyle(fontSize: 12, color: LauncherColors.of(context).muted),
    ),
  );
}
