import '../l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../core/java_discovery.dart';
import '../core/models.dart';
import 'theme.dart';

class JavaInstallationTile extends StatelessWidget {
  final JavaInstallation installation;
  final HostPlatform platform;
  final bool selected;
  final bool enabled;
  final int? requiredMajor;
  final VoidCallback onSelected;

  const JavaInstallationTile({
    required this.installation,
    required this.platform,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.requiredMajor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final java = installation;
    final sameArchitecture = java.architecture == platform.arch;
    final compatible =
        sameArchitecture &&
        (requiredMajor == null || java.major >= requiredMajor!);
    final warning = !sameArchitecture
        ? '与当前系统架构不匹配'
        : !compatible
        ? '需要 Java $requiredMajor 或更新版本'
        : null;
    return LTooltip(
      message:
          '${java.label}\n${java.vendor}\n${java.executable}'
          '${warning == null ? '' : '\n$warning'}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c.accentBackground : c.background,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? c.accent.withValues(alpha: .5) : c.border,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: LText(
                          java.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (warning != null) ...[
                        const SizedBox(width: 6),
                        Icon(FIcons.circleAlert, size: 12, color: c.muted),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${java.vendor} · ${java.executable}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 10, height: 1.2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FButton(
              size: FButtonSizeVariant.xs,
              mainAxisSize: MainAxisSize.min,
              variant: selected
                  ? FButtonVariant.primary
                  : FButtonVariant.outline,
              onPress: selected || !compatible || !enabled ? null : onSelected,
              child: LText(
                selected ? '已选择' : '使用此 Java',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
