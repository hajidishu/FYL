import 'package:flutter/material.dart';
import '../core/version_groups.dart';

class VersionGroupIcon extends StatelessWidget {
  final MinecraftVersionGroup group;
  final double size;
  const VersionGroupIcon(this.group, {this.size = 40, super.key});

  @override
  Widget build(BuildContext context) {
    final asset = switch (group) {
      MinecraftVersionGroup.release => 'minecraft',
      MinecraftVersionGroup.preview => 'command_block',
      MinecraftVersionGroup.historical => 'cobblestone',
      MinecraftVersionGroup.aprilFools => 'gold_block',
    };
    return Image.asset(
      'assets/components/$asset.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      excludeFromSemantics: true,
    );
  }
}
