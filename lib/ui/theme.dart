import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

class LauncherColors {
  final bool dark;
  const LauncherColors(this.dark);
  static LauncherColors of(BuildContext context) =>
      LauncherColors(Theme.of(context).brightness == Brightness.dark);
  Color get background =>
      dark ? const Color(0xFF101215) : const Color(0xFFF6F8F7);
  Color get sidebar => dark ? const Color(0xFF121518) : const Color(0xFFEDF1EF);
  Color get surface => dark ? const Color(0xFF1B1F24) : Colors.white;
  Color get raised => dark ? const Color(0xFF23292D) : const Color(0xFFEFF4F1);
  Color get border => dark ? const Color(0xFF2B3237) : const Color(0xFFDDE5DF);
  Color get foreground =>
      dark ? const Color(0xFFF0F3F2) : const Color(0xFF192820);
  Color get muted => dark ? const Color(0xFF8E9B99) : const Color(0xFF64776C);
  Color get accent => dark ? const Color(0xFFA3E5C4) : const Color(0xFF237852);
  Color get accentBackground =>
      dark ? const Color(0xFF263C33) : const Color(0xFFDDEEE4);
  Color get onAccent => dark ? const Color(0xFF10271C) : Colors.white;

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
    scaffoldBackgroundColor: background,
    fontFamily: 'Microsoft YaHei',
    fontFamilyFallback: const ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'],
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
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
  const Tag(this.text, {this.accent = false, super.key});
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent ? c.accentBackground : c.raised,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
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
    child: Text(label, style: const TextStyle(fontSize: 13)),
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
    super.key,
  });
  @override
  Widget build(BuildContext context) => FTextField(
    control: FTextFieldControl.managed(
      controller: controller,
      initial: controller == null ? TextEditingValue(text: initial) : null,
      onChange: onChanged == null ? null : (value) => onChanged!(value.text),
    ),
    label: label == null ? null : Text(label!),
    hint: hint,
    description: description == null ? null : Text(description!),
    error: error == null ? null : Text(error!),
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
  const SelectBox({
    required this.value,
    required this.items,
    this.onChanged,
    this.compact = false,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Container(
      height: compact ? 38 : null,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: c.background,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(7),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isDense: compact,
          isExpanded: true,
          value: value,
          dropdownColor: c.surface,
          borderRadius: BorderRadius.circular(8),
          style: TextStyle(color: c.foreground, fontSize: 13),
          icon: Icon(FIcons.chevronsUpDown, color: c.muted, size: 14),
          items: items.entries
              .map(
                (e) => DropdownMenuItem<T>(
                  value: e.key,
                  child: Text(e.value, overflow: TextOverflow.ellipsis),
                ),
              )
              .toList(),
          onChanged: onChanged == null
              ? null
              : (value) {
                  if (value != null) onChanged!(value);
                },
        ),
      ),
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
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 9),
          Text(
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
