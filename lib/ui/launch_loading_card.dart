import '../l10n/app_localizations.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/launch_progress.dart';
import 'theme.dart';

class LaunchLoadingCard extends StatelessWidget {
  final String instanceName;
  final LaunchProgress progress;
  final VoidCallback onStopWaiting;
  final Future<String?>? tip;
  const LaunchLoadingCard({
    required this.instanceName,
    required this.progress,
    required this.onStopWaiting,
    this.tip,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Surface(
      padding: const EdgeInsets.all(22),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 252),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              instanceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            const ChunkGenerationAnimation(),
            const SizedBox(height: 14),
            Semantics(
              liveRegion: true,
              child: LText(
                progress.label,
                key: const ValueKey('launch-stage'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.fraction,
                minHeight: 4,
                color: c.accent,
                backgroundColor: c.raised,
              ),
            ),
            if (tip != null)
              FutureBuilder<String?>(
                future: tip,
                builder: (context, snapshot) {
                  final text = snapshot.data;
                  if (text == null || text.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LText(
                          '小贴士',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: c.accent,
                          ),
                        ),
                        const SizedBox(height: 6),
                        LTooltip(
                          message: text,
                          child: LText(
                            text,
                            key: const ValueKey('launch-tip'),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: c.secondaryText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            if (progress.phase == LaunchPhase.window)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextButton(
                  key: const ValueKey('stop-waiting-for-window'),
                  onPressed: onStopWaiting,
                  child: const LText('停止等待'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// An overworld chunk assembles column by column, including soil and grass.
/// The loop is decorative; launch progress always comes from the real operation.
class ChunkGenerationAnimation extends StatefulWidget {
  const ChunkGenerationAnimation({super.key});
  @override
  State<ChunkGenerationAnimation> createState() =>
      _ChunkGenerationAnimationState();
}

class _ChunkGenerationAnimationState extends State<ChunkGenerationAnimation>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      animation.stop();
      animation.value = .8;
    } else if (!animation.isAnimating) {
      animation.repeat();
    }
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: 248,
      height: 124,
      child: AnimatedBuilder(
        animation: animation,
        builder: (_, _) => CustomPaint(
          painter: _ChunkPainter(
            animation.value,
            LauncherColors.of(context).dark,
          ),
        ),
      ),
    ),
  );
}

class _ChunkPainter extends CustomPainter {
  final double time;
  final bool dark;
  const _ChunkPainter(this.time, this.dark);
  static Path polygon(List<Offset> points) => Path()..addPolygon(points, true);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 248, size.height / 124);
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: dark ? .24 : .08);
    canvas.drawOval(const Rect.fromLTWH(38, 89, 172, 22), shadow);
    final opacity = time > .91 ? (1 - time) / .09 : 1.0;
    final paint = Paint()..isAntiAlias = false;
    void face(Path path, Color color) {
      canvas.drawPath(path, paint..color = color.withValues(alpha: opacity));
    }

    var index = 0;
    for (var depth = 0; depth <= 6; depth++) {
      for (var x = 0; x < 4; x++) {
        final z = depth - x;
        if (z < 0 || z >= 4) continue;
        final position = ((time * 1.6 - index++ * .035) / .34).clamp(0.0, 1.0);
        if (position <= 0) continue;
        final rise = Curves.easeOutCubic.transform(position);
        final height = (x == 1 || x == 2) && (z == 1 || z == 2) ? 2 : 1;
        for (var layer = 0; layer < height; layer++) {
          final center = Offset(
            124 + (x - z) * 18.0,
            34 + (x + z) * 8.0 - layer * 18 + (1 - rise) * 28,
          );
          final top = polygon([
            center + const Offset(0, -8),
            center + const Offset(18, 0),
            center + const Offset(0, 8),
            center + const Offset(-18, 0),
          ]);
          final left = polygon([
            center + const Offset(-18, 0),
            center + const Offset(0, 8),
            center + const Offset(0, 26),
            center + const Offset(-18, 18),
          ]);
          final right = polygon([
            center + const Offset(0, 8),
            center + const Offset(18, 0),
            center + const Offset(18, 18),
            center + const Offset(0, 26),
          ]);
          face(left, const Color(0xff80553b));
          face(right, const Color(0xff60402e));
          for (final side in [left, right]) {
            canvas.save();
            canvas.clipPath(side);
            for (var speck = 0; speck < 8; speck++) {
              final dx = ((speck * 7 + x * 3 + z * 5) % 33) - 16.0;
              final dy = ((speck * 11 + layer * 3) % 20) + 4.0;
              canvas.drawRect(
                Rect.fromLTWH(center.dx + dx, center.dy + dy, 3, 2),
                paint
                  ..color =
                      (speck.isEven
                              ? const Color(0xffa07750)
                              : const Color(0xff4f382b))
                          .withValues(alpha: opacity),
              );
            }
            if (layer == height - 1) {
              canvas.drawPath(
                polygon([
                  center + const Offset(-18, 0),
                  center + const Offset(0, 8),
                  center + const Offset(18, 0),
                  center + const Offset(18, 4),
                  center + const Offset(0, 12),
                  center + const Offset(-18, 4),
                ]),
                paint
                  ..color = const Color(0xff497a32).withValues(alpha: opacity),
              );
            }
            canvas.restore();
          }
          face(
            top,
            layer == height - 1
                ? const Color(0xff70a344)
                : const Color(0xff906044),
          );
          if (layer == height - 1) {
            canvas.save();
            canvas.clipPath(top);
            for (var patch = 0; patch < 6; patch++) {
              final dx = math.sin((x * 13 + z * 7 + patch) * 2) * 14;
              final dy = math.cos((z * 9 + x + patch) * 3) * 6;
              canvas.drawRect(
                Rect.fromLTWH(center.dx + dx, center.dy + dy, 4, 2),
                paint
                  ..color =
                      (patch.isEven
                              ? const Color(0xff588a36)
                              : const Color(0xff86b657))
                          .withValues(alpha: opacity),
              );
            }
            canvas.restore();
          }
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ChunkPainter oldDelegate) =>
      oldDelegate.time != time || oldDelegate.dark != dark;
}
