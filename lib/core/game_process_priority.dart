enum GameProcessPriority {
  idle('低'),
  belowNormal('低于正常'),
  normal('正常'),
  aboveNormal('高于正常'),
  high('高');

  final String label;
  const GameProcessPriority(this.label);

  static GameProcessPriority? fromName(Object? name) =>
      values.where((value) => value.name == name).firstOrNull;
}
