import 'dart:collection';
import 'dart:developer';

int _timestamp() => Timeline.now;

/// A bounded trailing window of network bytes, independent of UI refreshes.
class DownloadRate {
  static const _window = Duration(seconds: 3);
  static const _bucket = Duration(milliseconds: 100);
  static const _minimumInterval = Duration(milliseconds: 250);
  final int Function() _clock;
  final _samples = Queue<(int, int)>();
  late int _started;
  int _recentBytes = 0;

  DownloadRate({int Function()? clock}) : _clock = clock ?? _timestamp {
    _started = _clock();
  }

  void reset() {
    _samples.clear();
    _recentBytes = 0;
    _started = _clock();
  }

  void add(int bytes) {
    if (bytes <= 0) return;
    final now = _clock();
    _prune(now);
    if (_samples.isNotEmpty &&
        now - _samples.last.$1 < _bucket.inMicroseconds) {
      final previous = _samples.removeLast();
      _samples.add((previous.$1, previous.$2 + bytes));
    } else {
      _samples.add((now, bytes));
    }
    _recentBytes += bytes;
  }

  double get bytesPerSecond {
    final now = _clock();
    _prune(now);
    final elapsed = (now - _started).clamp(
      _minimumInterval.inMicroseconds,
      _window.inMicroseconds,
    );
    return _recentBytes * Duration.microsecondsPerSecond / elapsed;
  }

  void _prune(int now) {
    while (_samples.isNotEmpty &&
        now - _samples.first.$1 >= _window.inMicroseconds) {
      _recentBytes -= _samples.removeFirst().$2;
    }
  }
}
