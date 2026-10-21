import 'dart:io';
import 'package:flutter/material.dart';
import '../core/models.dart';
import 'component_icon.dart';

class InstanceIcon extends StatelessWidget {
  final GameInstance instance;
  final double size;
  const InstanceIcon(this.instance, {this.size = 40, super.key});
  @override
  Widget build(BuildContext context) {
    Widget fallback() => ComponentIcon(
      GameComponent.values.where((v) => v.name == instance.icon).firstOrNull ??
          componentFor(instance.components),
      size: size,
    );
    if (instance.icon == 'auto' ||
        GameComponent.values.any((v) => v.name == instance.icon)) {
      return fallback();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: Image.file(
        File(instance.icon),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback(),
      ),
    );
  }
}
