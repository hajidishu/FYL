String formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

String formatDownloadSpeed(double bytesPerSecond) {
  var value = bytesPerSecond.isFinite && bytesPerSecond > 0
      ? bytesPerSecond / 1024
      : 0.0;
  const units = ['KB/s', 'MB/s', 'GB/s'];
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}
