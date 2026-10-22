import 'package:flutter/material.dart';
import 'theme.dart';

class AccentPicker extends StatefulWidget {
  final int initial;
  const AccentPicker({required this.initial, super.key});
  @override
  State<AccentPicker> createState() => _AccentPickerState();
}

class _AccentPickerState extends State<AccentPicker> {
  late HSLColor color = HSLColor.fromColor(Color(0xff000000 | widget.initial));
  late final hex = TextEditingController(text: _hex(color.toColor()));
  String _hex(Color value) =>
      '#${(value.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  bool get valid => RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(hex.text.trim());
  void choose(HSLColor next) => setState(() {
    color = next;
    hex.text = _hex(next.toColor());
  });
  @override
  void dispose() {
    hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择色调'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 44,
              decoration: BoxDecoration(
                color: color.toColor(),
                borderRadius: BorderRadius.circular(9),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final value in [
                  0x237852,
                  0x2563eb,
                  0x7c3aed,
                  0xdb2777,
                  0xdc2626,
                  0xea580c,
                  0xca8a04,
                  0x475569,
                ])
                  InkWell(
                    onTap: () =>
                        choose(HSLColor.fromColor(Color(0xff000000 | value))),
                    child: Semantics(
                      label: _hex(Color(0xff000000 | value)),
                      button: true,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Color(0xff000000 | value),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            AppInput(
              key: const ValueKey('accent-hex'),
              controller: hex,
              label: '颜色值',
              hint: '#RRGGBB',
              error: valid ? null : '请输入六位十六进制颜色',
              onChanged: (value) => setState(() {
                if (valid) {
                  color = HSLColor.fromColor(
                    Color(
                      0xff000000 |
                          int.parse(
                            value.trim().replaceFirst('#', ''),
                            radix: 16,
                          ),
                    ),
                  );
                }
              }),
            ),
            const SizedBox(height: 10),
            const Text('色相'),
            Slider(
              key: const ValueKey('accent-hue'),
              value: color.hue,
              min: 0,
              max: 360,
              onChanged: (value) => choose(color.withHue(value)),
            ),
            const Text('饱和度'),
            Slider(
              value: color.saturation,
              onChanged: (value) => choose(color.withSaturation(value)),
            ),
            const Text('明度'),
            Slider(
              value: color.lightness,
              onChanged: (value) => choose(color.withLightness(value)),
            ),
          ],
        ),
      ),
    ),
    actions: [
      AppButton('取消', secondary: true, onPressed: () => Navigator.pop(context)),
      AppButton(
        '使用此色调',
        onPressed: valid
            ? () =>
                  Navigator.pop(context, color.toColor().toARGB32() & 0xffffff)
            : null,
      ),
    ],
  );
}
