/// Uses confirmed player positions while a composition is running. A stopped
/// decoder must not be hidden by an independently advancing UI clock.
class CompositionPlaybackClock {
  double _position = 0;
  bool _inTail = false;
  double? _nativePosition;
  int _sampleRevision = 0;

  double get position => _position;
  bool get inTail => _inTail;
  double? get nativePosition => _nativePosition;
  int get sampleRevision => _sampleRevision;

  void reset(double position) {
    _position = position;
    _inTail = false;
    _nativePosition = null;
    _sampleRevision = 0;
  }

  void sample({
    required double? nativePosition,
    required double compositionDuration,
    required double visibleDuration,
  }) {
    if (nativePosition == null ||
        !nativePosition.isFinite ||
        nativePosition < 0 ||
        !visibleDuration.isFinite ||
        visibleDuration <= 0) {
      return;
    }
    _nativePosition = nativePosition;
    _sampleRevision++;
    if (_inTail) {
      _position = _position.clamp(0.0, visibleDuration);
      return;
    }
    // The channel reports whole milliseconds; allow only that rounding error,
    // not the old 100 ms window which treated a stalled last frame as the end.
    final reachedEnd =
        compositionDuration.isFinite &&
        compositionDuration > 0 &&
        nativePosition >= compositionDuration - 0.001001;
    final hasTail =
        compositionDuration.isFinite &&
        compositionDuration > 0 &&
        compositionDuration < visibleDuration - 0.001001;
    // A seek to the end may land on the last video frame before play reaches
    // the actual item end. Keep a requested text-tail position during that gap.
    if (hasTail && !reachedEnd && _position >= compositionDuration) return;
    if (reachedEnd && hasTail) {
      _inTail = true;
      if (_position < compositionDuration) _position = compositionDuration;
      _position = _position.clamp(0.0, visibleDuration);
    } else {
      final p = reachedEnd && nativePosition < compositionDuration
          ? compositionDuration
          : nativePosition;
      _position = p.clamp(0.0, visibleDuration);
    }
  }

  /// Only a confirmed, completed composition may hand its clock to a visible
  /// text/sticker tail. Ordinary playback never extrapolates over a stall.
  void advanceTail(double seconds, {required double visibleDuration}) {
    if (!_inTail || !seconds.isFinite || seconds <= 0) return;
    _position = (_position + seconds).clamp(0.0, visibleDuration);
  }
}
