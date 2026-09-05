import 'dart:async';

/// A single decoder follows the latest viewport. Requests replaced while a
/// decode is in flight never form a backlog. Neighbours go after visible frames.
class ScrubFrameQueue<T> {
  ScrubFrameQueue({
    required this.load,
    required this.onFrame,
    required this.canRun,
  });

  final Future<T?> Function(ScrubFrameRequest) load;
  final void Function(ScrubFrameRequest, T) onFrame;
  final bool Function() canRun;
  final List<ScrubFrameRequest> _pending = [];
  ScrubFrameRequest? _inFlight;
  int _inFlightGeneration = -1;
  bool _disposed = false;
  int _generation = 0;

  void request(Iterable<ScrubFrameRequest> requests) {
    if (_disposed) return;
    _pending.clear();
    final seen = <ScrubFrameRequest>{};
    for (final r in requests) {
      if ((r != _inFlight || _inFlightGeneration != _generation) &&
          seen.add(r)) {
        _pending.add(r);
      }
    }
    unawaited(_pump());
  }

  /// Invalidate in-flight results too (export, media replacement, disposal).
  void clear() {
    _generation++;
    _pending.clear();
  }

  void dispose() {
    _disposed = true;
    clear();
  }

  Future<void> _pump() async {
    if (_inFlight != null) return;
    while (!_disposed && _pending.isNotEmpty) {
      if (!canRun()) {
        _pending.clear();
        return;
      }
      final r = _pending.removeAt(0);
      final generation = _generation;
      _inFlight = r;
      _inFlightGeneration = generation;
      try {
        final frame = await load(r);
        if (!_disposed &&
            generation == _generation &&
            canRun() &&
            frame != null) {
          onFrame(r, frame);
        }
      } finally {
        _inFlight = null;
      }
    }
  }
}

/// Time is quantized to the cache slot, so tiny pointer movements reuse a frame.
class ScrubFrameRequest {
  const ScrubFrameRequest({
    required this.source,
    required this.path,
    required this.slot,
    required this.seconds,
  });

  final int source;
  final String path;
  final int slot;
  final double seconds;

  @override
  bool operator ==(Object other) =>
      other is ScrubFrameRequest &&
      source == other.source &&
      path == other.path &&
      slot == other.slot &&
      seconds == other.seconds;

  @override
  int get hashCode => Object.hash(source, path, slot, seconds);
}
