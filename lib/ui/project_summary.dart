import 'package:flutter/material.dart';

import '../core/community_models.dart';
import 'theme.dart';

class ProjectSummary extends StatelessWidget {
  final ContentProject project;
  const ProjectSummary(this.project, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final categories = project.categories
        .map((category) => category.trim())
        .where((category) => category.isNotEmpty)
        .where(
          (category) => !const {
            'fabric',
            'forge',
            'neoforge',
            'quilt',
            'iris',
            'optifine',
            'minecraft',
            'mod',
            'modpack',
          }.contains(category.toLowerCase()),
        )
        .toSet()
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
        final count = constraints.maxWidth >= 640 * scale ? 2 : 1;
        final visible = categories.take(count).toList();
        return Row(
          children: [
            if (categories.isNotEmpty &&
                constraints.maxWidth >= 240 * scale) ...[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * .32,
                ),
                child: Tooltip(
                  message: categories.join(' · '),
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < visible.length; i++) ...[
                        if (i > 0) const SizedBox(width: 4),
                        Flexible(child: Tag(visible[i], compact: true)),
                      ],
                      if (categories.length > visible.length) ...[
                        const SizedBox(width: 4),
                        Tag(
                          '+${categories.length - visible.length}',
                          compact: true,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 9),
            ],
            Expanded(
              child: Tooltip(
                message: project.summary,
                constraints: const BoxConstraints(maxWidth: 480),
                child: Text(
                  project.summary.replaceAll(RegExp(r'\s+'), ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.secondaryText,
                    fontSize: 13,
                    height: 1.45,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
