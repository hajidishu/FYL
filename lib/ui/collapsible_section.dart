import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../l10n/app_localizations.dart';
import 'theme.dart';

class CollapsibleSection extends StatefulWidget {
  final String title;
  final Widget child;
  final IconData? icon;
  final bool initiallyExpanded;

  const CollapsibleSection({
    required this.title,
    required this.child,
    this.icon,
    this.initiallyExpanded = false,
    super.key,
  });

  @override
  State<CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<CollapsibleSection> {
  late bool expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Material(
          color: c.raised,
          child: ExpansionTile(
            initiallyExpanded: widget.initiallyExpanded,
            onExpansionChanged: (value) => setState(() => expanded = value),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 2,
            ),
            minTileHeight: 44,
            shape: const Border(),
            collapsedShape: const Border(),
            backgroundColor: c.raised,
            collapsedBackgroundColor: c.raised,
            expansionAnimationStyle: reduceMotion
                ? AnimationStyle.noAnimation
                : null,
            leading: widget.icon == null
                ? null
                : Icon(widget.icon, size: 17, color: c.secondaryText),
            title: LText(
              widget.title,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                fontWeight: FontWeight.w500,
                color: c.foreground,
              ),
            ),
            trailing: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: c.border),
              ),
              child: AnimatedRotation(
                turns: expanded ? .5 : 0,
                duration: Duration(milliseconds: reduceMotion ? 0 : 160),
                child: Icon(FIcons.chevronDown, size: 16, color: c.foreground),
              ),
            ),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border(top: BorderSide(color: c.border)),
                ),
                child: widget.child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
