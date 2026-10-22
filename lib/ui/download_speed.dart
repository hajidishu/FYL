import 'dart:async';
import 'package:flutter/material.dart';
import '../core/download_rate.dart';
import 'byte_size.dart';
import 'theme.dart';

class DownloadSpeed extends StatefulWidget {
  final DownloadRate rate;
  const DownloadSpeed(this.rate, {super.key});

  @override
  State<DownloadSpeed> createState() => _DownloadSpeedState();
}

class _DownloadSpeedState extends State<DownloadSpeed> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    '速度 ${formatDownloadSpeed(widget.rate.bytesPerSecond)}',
    style: TextStyle(color: LauncherColors.of(context).muted, fontSize: 12),
  );
}
