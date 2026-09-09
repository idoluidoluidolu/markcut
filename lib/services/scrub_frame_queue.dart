import 'dart:async';
import 'dart:math' as math;

/// 抽一格拖曳幀允許差幾毫秒（給原生 AVAssetImageGenerator 的容忍值）。
///
/// 工作檔維持 150ms；原檔最多 250ms，放寬少量解碼彈性，同時限制
/// 畫面與播放頭的偏差。容差不保證回傳最近的關鍵幀；原生尚未回報
/// actualTime，不能放寬到整支長度後把任意時間的影格當成指定格。
/// Android 的抽幀器只拿關鍵幀，這個值對它沒作用。
int scrubFrameTolMs({required bool rawSource, required double duration}) {
  const fine = 150;
  if (!rawSource) return fine;
  if (!duration.isFinite || duration <= 0) return fine;
  return math.min(250, math.max(fine, (duration * 1000).ceil()));
}

/// 合成播放器（原生拖曳／seek）一發 seek 允許差幾毫秒。
///
/// 原生端最多收 500（AppDelegate 的 tolerance(exact:milliseconds:)，註解
/// 寫著「原始長 GOP 影片才由 Dart 明確要求寬容拖曳」），放手的精準發不管
/// 傳什麼一律 0。
///
/// 原檔拖動時給滿 500：±0.5 秒＝1 秒的窗，手機錄的 HEVC 關鍵幀每 6~30
/// 格（最疏約 1 秒），窗裡一定有關鍵幀，AVPlayer 就直接落在最近的那個
/// ——往前往回都是解一張，成本對稱。以前送 150：±150ms 的窗多半沒有
/// 關鍵幀，播放器只好從前一個關鍵幀一路解到目標，往回滑每一格都吃滿
/// 這個成本（實測回報「往右滑後往回滑很不順」；程式碼自己也寫著「向後
/// seek 要回到前一個關鍵幀重解」）。拖動中畫面在關鍵幀之間跳、手一停
/// 那發精準 seek 對準——跟 Edits 一樣。代理（密關鍵幀）維持 0：seek 本
/// 來就 2~9ms，不需要
int compScrubToleranceMs({required bool exact, required bool raw}) {
  if (exact || !raw) return 0;
  return kCompScrubToleranceCapMs;
}

/// 合成播放器拖動容忍值的上限（毫秒）——跟原生端
/// MCSeekCompletionState.scrubToleranceCapMs 同一個數。CompPlayer 送去原生
/// 前用它夾；以前 Dart 這邊夾在 250、原生 500，兩邊不一致，Dart 想給 500
/// 也送不到（測試抓到 Actual: 250）
const kCompScrubToleranceCapMs = 500;

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
