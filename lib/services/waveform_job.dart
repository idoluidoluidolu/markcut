import 'dart:async';

class WaveformJob {
  bool cancelled = false;
  Future<void> Function()? onCancel;
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    final callback = onCancel;
    if (callback != null) unawaited(callback().catchError((_) {}));
  }
}
