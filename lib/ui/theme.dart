import '../l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

class LauncherAccent extends ThemeExtension<LauncherAccent> {
  final int? color;
  const LauncherAccent(this.color);
  @override
  LauncherAccent copyWith({int? color}) => LauncherAccent(color ?? this.color);
  @override
  LauncherAccent lerp(covariant LauncherAccent? other, double t) =>
      t < .5 ? this : other ?? this;
}

class LauncherColors {
  final bool dark;
  final int? accentColor;
  const LauncherColors(this.dark, {this.accentColor});
  static LauncherColors of(BuildContext context) => LauncherColors(
    Theme.of(context).brightness == Brightness.dark,
    accentColor: Theme.of(context).extension<LauncherAccent>()?.color,
  );
  Color get background =>
      dark ? const Color(0xFF101215) : const Color(0xFFF6F8F7);
  Color get sidebar => dark ? const Color(0xFF121518) : const Color(0xFFEDF1EF);
  Color get surface => dark ? const Color(0xFF1B1F24) : Colors.white;
  Color get raised => dark ? const Color(0xFF23292D) : const Color(0xFFEFF4F1);
  Color get border => dark ? const Color(0xFF2B3237) : const Color(0xFFDDE5DF);
  Color get foreground =>
      dark ? const Color(0xFFF0F3F2) : const Color(0xFF192820);
  Color get muted => dark ? const Color(0xFF8E9B99) : const Color(0xFF64776C);
  Color get secondaryText =>
      dark ? const Color(0xFFBAC5C1) : const Color(0xFF4C6255);
  Color get accent {
    if (accentColor == null) {
      return dark ? const Color(0xFFA3E5C4) : const Color(0xFF237852);
    }
    final hsl = HSLColor.fromColor(Color(0xff000000 | accentColor!));
    return hsl
        .withLightness(hsl.lightness.clamp(dark ? .65 : .25, dark ? .82 : .45))
        .toColor();
  }

  Color get accentBackground => accentColor == null
      ? (dark ? const Color(0xFF263C33) : const Color(0xFFDDEEE4))
      : Color.alphaBlend(accent.withValues(alpha: dark ? .16 : .12), surface);
  Color get onAccent => accentColor == null
      ? (dark ? const Color(0xFF10271C) : Colors.white)
      : ThemeData.estimateBrightnessForColor(accent) == Brightness.light
      ? const Color(0xFF101215)
      : Colors.white;

  FThemeData get forui => FThemeData(
    touch: false,
    colors: (dark ? FColors.neutralDark : FColors.neutralLight).copyWith(
      background: background,
      foreground: foreground,
      card: surface,
      primary: accent,
      primaryForeground: onAccent,
      secondary: raised,
      secondaryForeground: foreground,
      muted: raised,
      mutedForeground: muted,
      border: border,
    ),
  );

  ThemeData get material => ThemeData(
    brightness: dark ? Brightness.dark : Brightness.light,
    extensions: [LauncherAccent(accentColor)],
    scaffoldBackgroundColor: background,
    fontFamily: 'Microsoft YaHei',
    fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: dark ? Brightness.dark : Brightness.light,
    ).copyWith(primary: accent, onPrimary: onAccent, secondary: accent),
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: 13, height: 1.5, color: foreground),
    ),
    dividerColor: border,
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: raised,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(color: foreground, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(muted.withValues(alpha: .3)),
      radius: const Radius.circular(5),
    ),
  );
}

class Surface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  const Surface({
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.color,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? c.surface,
        border: Border.all(color: c.border.withValues(alpha: .65)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

class Tag extends StatelessWidget {
  final String text;
  final bool accent;
  final bool compact;
  final bool localize;
  const Tag(
    this.text, {
    this.accent = false,
    this.compact = false,
    this.localize = true,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 9,
        vertical: compact ? 1 : 4,
      ),
      decoration: BoxDecoration(
        color: accent ? c.accentBackground : c.raised,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        localize ? AppLocalizations.of(context).text(text) : text,
        maxLines: compact ? 1 : null,
        overflow: compact ? TextOverflow.ellipsis : null,
        style: TextStyle(
          fontSize: 12,
          height: compact ? 1.2 : null,
          letterSpacing: 0,
          fontWeight: FontWeight.w500,
          color: accent ? c.accent : c.muted,
        ),
      ),
    );
  }
}

class AppButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool secondary;
  final bool small;
  const AppButton(
    this.label, {
    this.icon,
    this.onPressed,
    this.secondary = false,
    this.small = false,
    super.key,
  });
  @override
  Widget build(BuildContext context) => FButton(
    onPress: onPressed,
    variant: secondary ? FButtonVariant.outline : FButtonVariant.primary,
    size: small ? FButtonSizeVariant.sm : FButtonSizeVariant.lg,
    mainAxisSize: MainAxisSize.min,
    prefix: icon == null ? null : Icon(icon, size: 16),
    child: LText(label, style: const TextStyle(fontSize: 13)),
  );
}

class AppInput extends StatelessWidget {
  final String initial;
  final String? hint;
  final String? label;
  final String? description;
  final String? error;
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;
  final bool enabled;
  final int maxLines;
  final bool obscureText;
  final bool compact;
  const AppInput({
    this.initial = '',
    this.hint,
    this.label,
    this.description,
    this.error,
    this.onChanged,
    this.controller,
    this.enabled = true,
    this.maxLines = 1,
    this.obscureText = false,
    this.compact = false,
    super.key,
  });
  @override
  Widget build(BuildContext context) => FTextField(
    size: compact ? FTextFieldSizeVariant.sm : FTextFieldSizeVariant.md,
    control: FTextFieldControl.managed(
      controller: controller,
      initial: controller == null ? TextEditingValue(text: initial) : null,
      onChange: onChanged == null ? null : (value) => onChanged!(value.text),
    ),
    label: label == null ? null : LText(label!),
    hint: hint == null ? null : AppLocalizations.of(context).text(hint!),
    description: description == null ? null : LText(description!),
    error: error == null ? null : LText(error!),
    enabled: enabled,
    maxLines: maxLines,
    obscureText: obscureText,
    autocorrect: false,
    spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
  );
}

class SelectBox<T> extends StatelessWidget {
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;
  final bool compact;
  final bool localizeItems;
  const SelectBox({
    required this.value,
    required this.items,
    this.onChanged,
    this.compact = false,
    this.localizeItems = true,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return FSelect<T>.rich(
      control: FSelectControl<T>.lifted(
        value: items.containsKey(value) ? value : null,
        onChange: (selected) {
          if (selected != null) onChanged?.call(selected);
        },
      ),
      enabled: onChanged != null && items.isNotEmpty,
      size: compact ? FTextFieldSizeVariant.sm : FTextFieldSizeVariant.md,
      format: (selected) => localizeItems
          ? AppLocalizations.of(context).text(items[selected] ?? '')
          : items[selected] ?? '',
      contentConstraints: const FAutoWidthPortalConstraints(maxHeight: 280),
      style: FSelectStyleDelta.delta(
        contentStyle: FSelectContentStyleDelta.delta(
          padding: const EdgeInsetsGeometryDelta.value(EdgeInsets.all(6)),
          decoration: DecorationDelta.value(
            BoxDecoration(
              color: c.surface,
              border: Border.all(color: c.border),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: c.dark ? .25 : .09),
                  blurRadius: 18,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
          ),
        ),
      ),
      children: [
        for (final entry in items.entries)
          FSelectItem<T>(
            value: entry.key,
            title: Text(
              localizeItems
                  ? AppLocalizations.of(context).text(entry.value)
                  : entry.value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final Widget? action;
  const EmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 46, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: c.accentBackground,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(icon, color: c.accent, size: 30),
          ),
          const SizedBox(height: 22),
          LText(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 9),
          LText(
            description,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.muted, height: 1.8),
          ),
          if (action != null) ...[const SizedBox(height: 24), action!],
        ],
      ),
    );
  }
}
