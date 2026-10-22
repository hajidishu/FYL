import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

Future<String> importLauncherBackground(
  String source,
  String supportDirectory,
) async {
  final file = File(source);
  if (await file.length() > 32 * 1024 * 1024) {
    throw const FormatException('请选择小于 32 MB 的图片。');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(
    await file.readAsBytes(),
  );
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final scale = math.min(
        1.0,
        2560 / math.max(descriptor.width, descriptor.height),
      );
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) throw const FormatException('无法读取所选图片。');
          final bytes = data.buffer.asUint8List();
          final target = File(
            p.join(
              supportDirectory,
              'appearance',
              'backgrounds',
              '${sha256.convert(bytes)}.png',
            ),
          );
          await target.parent.create(recursive: true);
          if (!await target.exists()) {
            await target.writeAsBytes(bytes, flush: true);
          }
          return target.path;
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

class LauncherBackground extends StatelessWidget {
  final String? path;
  final double opacity;
  final Widget child;
  const LauncherBackground({
    required this.child,
    this.path,
    this.opacity = .35,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (path?.isNotEmpty == true)
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: opacity.clamp(0, 1),
              child: Image.file(
                File(path!),
                key: const ValueKey('launcher-background-image'),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      child,
    ],
  );
}
