enum LaunchPhase {
  account('验证游戏账号', .02),
  metadata('读取版本信息', .10),
  java('检查 Java', .18),
  files('校验游戏文件', .27),
  natives('准备运行环境', .55),
  resources('准备游戏资源', .65),
  memory('配置游戏内存', .75),
  hook('执行启动前命令', .81),
  process('启动游戏进程', .88),
  window('等待游戏窗口', .94);

  final String label;
  final double position;
  const LaunchPhase(this.label, this.position);
}

class LaunchProgress {
  final LaunchPhase phase;
  final int completed, total;
  const LaunchProgress(this.phase, {this.completed = 0, this.total = 0});
  String get label =>
      total > 0 ? '${phase.label} · $completed / $total' : phase.label;
  double? get fraction {
    if (phase == LaunchPhase.window) return null;
    if (total <= 0) return phase.position;
    final next = LaunchPhase.values[phase.index + 1].position;
    return phase.position +
        (next - phase.position) * (completed / total).clamp(0, 1);
  }
}
