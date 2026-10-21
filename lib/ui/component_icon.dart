import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum GameComponent { minecraft, forge, neoforge, fabric, optifine, optifabric }

GameComponent componentFor(String components) {
  final value = components.toLowerCase();
  for (final component in [
    GameComponent.neoforge,
    GameComponent.forge,
    GameComponent.fabric,
    GameComponent.optifine,
    GameComponent.optifabric,
  ]) {
    if (RegExp('(^|[^a-z])${component.name}([^a-z]|\$)').hasMatch(value)) {
      return component;
    }
  }
  return GameComponent.minecraft;
}

class ComponentIcon extends StatelessWidget {
  final GameComponent component;
  final double size;
  const ComponentIcon(this.component, {this.size = 40, super.key});

  @override
  Widget build(BuildContext context) {
    if (component == GameComponent.neoforge ||
        component == GameComponent.fabric) {
      return SvgPicture.asset(
        'assets/components/${component.name}.svg',
        width: size,
        height: size,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
      );
    }
    return Image.asset(
      'assets/components/${component.name}.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: component == GameComponent.optifine
          ? FilterQuality.none
          : FilterQuality.high,
      excludeFromSemantics: true,
    );
  }
}
