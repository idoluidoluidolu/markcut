import 'dart:async';

/// Bound interactive seek submissions, not the displayed frame rate. AVPlayer
/// still chases its latest target. Exact release seeks bypass the cadence and
/// discard pending approximate work so an older target cannot follow them.
class PreviewSeekDispatcher {
  PreviewSeekDispatcher({this.interval = const Duration(microseconds: 16667)});

  final Duration interval;
  Timer? _timer;
  void Function()? _pending;
  bool _disposed = false;
  int coalesced = 0;

  void submit(void Function() send, {required bool exact}) {
    if (_disposed) return;
    if (exact) {
      cancel();
      send();
      return;
    }
    if (_timer != null) {
      if (_pending != null) coalesced++;
      _pending = send;
      return;
    }
    _arm();
    send();
  }

  void _arm() {
    _timer = Timer(interval, () {
      _timer = null;
      final send = _pending;
      _pending = null;
      if (send == null || _disposed) return;
      _arm();
      send();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
