import 'package:flutter/material.dart';

import '../core/game_process_priority.dart';
import 'theme.dart';

class GameProcessPrioritySetting extends StatelessWidget {
  final GameProcessPriority? value;
  final GameProcessPriority? inherited;
  final ValueChanged<GameProcessPriority?>? onChanged;
  final String scope;

  const GameProcessPrioritySetting({
    required this.value,
    required this.onChanged,
    required this.scope,
    this.inherited,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final resetValue = inherited == null ? GameProcessPriority.normal : null;
    return SettingsRow(
      label: '游戏进程优先级',
      child: Row(
        children: [
          Expanded(
            child: SelectBox<String>(
              key: ValueKey('$scope-game-priority'),
              compact: true,
              value:
                  value?.name ??
                  (inherited == null
                      ? GameProcessPriority.normal.name
                      : 'inherit'),
              items: {
                if (inherited != null) 'inherit': '跟随全局（${inherited!.label}）',
                for (final priority in GameProcessPriority.values)
                  priority.name: priority.label,
              },
              onChanged: onChanged == null
                  ? null
                  : (value) => onChanged!(GameProcessPriority.fromName(value)),
            ),
          ),
          const SizedBox(width: 8),
          AppButton(
            '重置',
            key: ValueKey('reset-$scope-game-priority'),
            secondary: true,
            small: true,
            onPressed: onChanged == null || value == resetValue
                ? null
                : () => onChanged!(resetValue),
          ),
        ],
      ),
    );
  }
}
