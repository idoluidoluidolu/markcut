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
/// 那發精準 seek 對準——跟 Edits 一樣。
///
/// 代理（密關鍵幀）本來給 0，理由是「seek 本來就 2~9ms」。那只算了 seek，
/// 漏了容忍值的第二個作用：它同時是原生拖曳快取的收件窗
/// （MCNativeScrubCache.accepts）。給 0＝窗只剩 1ms＝快取形同關閉，每一格
/// 都要重新解碼＋重跑一次 CI 合成。實測 199 兩份診斷對照得很清楚：
/// 原檔（窗 500）快取命中 210、未命中 11、呈現 218/221、平均 30ms；
/// 代理落地後（窗 0）26 秒滑動 312 發 seek 產生 310 格 CI 重畫，命中掛零。
/// 往右滑感覺不到是因為解碼器本來就往前串流；一轉向 AVPlayer 要清管線、
/// 回關鍵幀重灌，那一格就是使用者說的「往左滑會卡一下、往左再往右一定
/// 卡一下」（CI 逐格的 58ms／73ms 慢格正落在兩個轉向點上）。
///
/// 代理不必給到 500：它的 GOP 只有 5 格（167ms），
/// [kCompScrubDenseToleranceMs] 250ms 就保證窗裡有關鍵幀，同時給快取一個
/// ±250ms 的收件窗——轉向時上一格多半就在裡面，直接貼出來，不必等重灌。
/// 拖動中畫面最多差 250ms（螢幕截圖那個縮放下約 19px），手一停照樣精準
int compScrubToleranceMs({required bool exact, required bool raw}) {
  if (exact) return 0;
  return raw ? kCompScrubToleranceCapMs : kCompScrubDenseToleranceMs;
}

/// 代理／工作檔（關鍵幀每 5 格＝167ms）拖動的容忍窗：≥1 個 GOP，窗裡
/// 一定有關鍵幀；同時是原生拖曳快取的收件窗（見 [compScrubToleranceMs]）
const kCompScrubDenseToleranceMs = 250;

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
