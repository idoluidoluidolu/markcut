import 'dart:math' as math;

/// 批次匯出的兩種東西：一張照片跟一部影片差好幾個數量級，
/// 平均要分開算，不然做完三張照片之後會告訴你剩下那部影片 2 秒就好
enum ExportKind { photo, video }

/// 批次匯出的「約還要多久」——純算術，沒有 Timer、沒有 UI。
///
/// 怎麼算：
/// - 以「完成時間差」當樣本：第 k 個完成的時間減第 k-1 個完成的時間
///  （第一個減開始時間）。這是實際吞吐量，就算匯出在背後是流水線
///  （下一張在畫、上一張在存）也不會算錯；
/// - 每種類型各自平均；剩下的 = Σ 剩下每個的 avg(其類型)，再扣掉
///   目前這個已經跑掉的時間（影片有進度百分比就用百分比）；
/// - 有任何一種「還沒做完過一個」的類型排在後面 → 回 null（估算中）。
///   刻意不用另一種類型去猜（照片跟影片沒有固定倍率，猜了只會亂跳）。
///
/// 平滑：讀數在兩次完成之間會自己每秒倒數；新的估計比目前讀數
/// 「多一點點」（3 秒或 15% 以內）時不往上跳、繼續倒數——每張照片
/// 慢個零點幾秒都讓數字往上蹦一下很難看。真的變多（例如照片之後
/// 輪到影片）才接受
class ExportEta {
  ExportEta({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  DateTime? _start;
  DateTime? _lastDone;
  double _currentProgress = 0;
  final Map<ExportKind, List<double>> _samples = {
    ExportKind.photo: [],
    ExportKind.video: [],
  };

  /// 上一次給出的讀數（秒）與給出的時間：倒數與防蹦跳用
  double? _shownSec;
  DateTime? _shownAt;

  bool get started => _start != null;

  void start() {
    _start = _clock();
    _lastDone = _start;
    _currentProgress = 0;
  }

  /// 目前這個項目的進度（0~1；影片匯出會回報，照片沒有就不用叫）
  void noteProgress(double p) {
    _currentProgress = p.clamp(0.0, 1.0);
  }

  /// 目前這個項目做完了（成功失敗都算：時間都花了）
  void itemDone(ExportKind kind) {
    final now = _clock();
    final from = _lastDone ?? _start ?? now;
    _samples[kind]!.add(now.difference(from).inMilliseconds / 1000);
    _lastDone = now;
    _currentProgress = 0;
  }

  double? averageOf(ExportKind kind) {
    final s = _samples[kind]!;
    if (s.isEmpty) return null;
    return s.reduce((a, b) => a + b) / s.length;
  }

  /// 剩下的秒數（原始估計，不平滑）。[current] 是正在做的那個，
  /// [after] 是排在它後面的；任何一種沒樣本就回 null
  double? rawRemaining(ExportKind current, Iterable<ExportKind> after) {
    if (_start == null) return null;
    final now = _clock();
    final curAvg = averageOf(current);
    if (curAvg == null) return null;
    var total = 0.0;
    for (final k in after) {
      final a = averageOf(k);
      if (a == null) return null;
      total += a;
    }
    // 目前這個：有進度用進度，沒有就用「平均扣掉已經跑掉的」
    final elapsed = now.difference(_lastDone ?? _start!).inMilliseconds / 1000;
    final curLeft = _currentProgress > 0
        ? curAvg * (1 - _currentProgress)
        : curAvg - elapsed;
    return total + math.max(0.0, curLeft);
  }

  /// 平滑後的讀數（整數秒）；null＝估算中
  int? remainingSec(ExportKind current, Iterable<ExportKind> after) {
    final raw = rawRemaining(current, after);
    if (raw == null) return null;
    final now = _clock();
    var pick = raw;
    final shown = _shownSec;
    final shownAt = _shownAt;
    if (shown != null && shownAt != null) {
      final countdown = math.max(
        0.0,
        shown - now.difference(shownAt).inMilliseconds / 1000,
      );
      final bump = raw - countdown;
      if (bump > 0 && bump <= math.max(3.0, countdown * 0.15)) {
        pick = countdown; // 只多一點點：不往上跳，繼續倒數
      }
    }
    _shownSec = pick;
    _shownAt = now;
    return pick.round();
  }

  /// 進度視窗那一行：「第 3 / 12 個 · 約還要 40 秒」
  String label(
    int index1,
    int total,
    ExportKind current,
    Iterable<ExportKind> after,
  ) {
    final sec = remainingSec(current, after);
    return '第 $index1 / $total 個 · ${formatRemaining(sec)}';
  }

  /// null → 估算中；<1 秒 → 快好了；<60 → 約還要 N 秒；
  /// 其他 → 約還要 M 分 N 秒
  static String formatRemaining(int? sec) {
    if (sec == null) return '估算中…';
    if (sec < 1) return '快好了';
    if (sec < 60) return '約還要 $sec 秒';
    final m = sec ~/ 60, s = sec % 60;
    return s == 0 ? '約還要 $m 分' : '約還要 $m 分 $s 秒';
  }
}
