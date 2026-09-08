import 'dart:async';
import 'dart:math' as math;

/// 抽一格拖曳幀允許差幾毫秒（給原生 AVAssetImageGenerator 的容忍值）。
///
/// 工作檔（密關鍵幀）：0.15 秒——就近取材、幾乎逐格精準，這是原本的值。
/// 原檔（秒進期間工作檔還在背景轉）：整支長度＝直接拿最近的關鍵幀。
///
/// 手機錄的 HEVC 一個 GOP 一到兩秒，150ms 的容忍逼得解碼器從前一個
/// 關鍵幀一路解到目標——4K 一格就是幾十張、幾百毫秒，還跟背景轉檔搶
/// 同一顆硬體解碼器；一次匯入好幾支就是「進去馬上滑超頓、要等一陣子
///（其實是等工作檔轉好）才回覆」（實測回報）。關鍵幀貼齊一格只解一張，
/// 滑動中畫面粗一點（在關鍵幀之間跳）沒關係——手一停，收尾那一發精準
/// seek（_tryEndScrub）會把正確的那格帶出來。
/// Android 的抽幀器本來就只拿關鍵幀，這個值對它沒作用
int scrubFrameTolMs({required bool rawSource, required double duration}) {
  const fine = 150;
  if (!rawSource) return fine;
  return math.max(fine, (duration * 1000).ceil());
}

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
      } catch (_) {
        // A corrupt/unavailable frame must not abort the newest viewport's
        // pending work or leak an unhandled error from this background task.
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
