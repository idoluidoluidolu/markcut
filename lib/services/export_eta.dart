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

  /// 上一次給出的讀數：倒數與防蹦跳用（見 [_EtaSmoother]）
  final _EtaSmoother _smooth = _EtaSmoother();

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
    return _smooth.apply(raw, _clock());
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
  static String formatRemaining(int? sec) => _formatRemaining(sec);
}

/// null → 估算中；<1 秒 → 快好了；<60 → 約還要 N 秒；
/// 其他 → 約還要 M 分 N 秒。匯出與匯入共用同一套說法
String _formatRemaining(int? sec) {
  if (sec == null) return '估算中…';
  if (sec < 1) return '快好了';
  if (sec < 60) return '約還要 $sec 秒';
  final m = sec ~/ 60, s = sec % 60;
  return s == 0 ? '約還要 $m 分' : '約還要 $m 分 $s 秒';
}

/// 讀數平滑（匯出與匯入共用）。
///
/// 兩件事：讀數在兩次重算之間自己倒數；新的估計比目前讀數「多一點點」
///（3 秒或 15% 以內）時不往上跳、繼續倒數——每個項目慢個零點幾秒都
/// 讓數字往上蹦一下很難看。真的變多才接受
class _EtaSmoother {
  double? _shownSec;
  DateTime? _shownAt;

  int apply(double raw, DateTime now) {
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
}

/// 匯入（進場遮罩）的「約還要多久」——純算術，沒有 Timer、沒有 UI。
///
/// 跟 [ExportEta] 的差別在「一個項目要多久」怎麼來。批次匯出的一張
/// 照片跟下一張照片成本差不多，用「完成時間差」平均就夠；匯入是轉檔，
/// 一支 5 秒的素材跟一支 3 分鐘的素材差 36 倍，把它們平均起來沒有意義。
/// 轉檔真正穩定的量是**倍速**（素材秒數 ÷ 轉檔牆鐘秒數——原生端每轉好
/// 一支就回報一次「素材 Ns → N 倍速」），而每支素材的長度在轉檔開始前
/// 就知道（probeLite 已經探過）。所以這裡估的是
///「剩下的素材秒數 ÷ 倍速 ＋ 尾巴」。
///
/// 倍速哪裡來（三段，越前面越可信）：
/// 1. 已經轉完的：Σ素材秒 ÷ Σ牆鐘秒。整批平均而不是逐支平均——
///    長片的權重本來就該大；
/// 2. 一支都還沒轉完，但正在轉的這支已經回報進度（原生端每 200ms
///    送一次 t/dur）：(進度 × 素材秒) ÷ 已經跑掉的牆鐘秒。要跑滿
///    [warmSec] 又真的有進度才算——開檔那一兩秒還沒有影格出來，
///    這時候量到的是 0.1 倍速，讀數會從「還要 20 分鐘」開始往下掉；
/// 3. 什麼都還沒有 → null＝「估算中…」。
///
/// 為什麼不用「保守先驗（例如 2 倍速）」開場：那是猜的，而這裡有現成
/// 的真實訊號——第一支轉不到兩秒就量得到自己這台機器、這支素材的
/// 真倍速。猜錯的代價是使用者看著數字從 3 分鐘掉到 20 秒（或反過來），
/// 比晚一兩秒才出現數字難看得多
class ImportEta {
  ImportEta({
    DateTime Function()? clock,
    double? tailSec,
    this.perItemSec = 0.3,
    this.warmSec = 1.5,
  }) : _clock = clock ?? DateTime.now,
       tailSec = tailSec ?? learnedTailSec;

  final DateTime Function() _clock;

  /// 轉檔以外的收尾（組合成播放器、遮罩收掉）大約要多久。
  /// 沒有它的話最後一支轉完的瞬間讀數就歸零，畫面卻還要組幾秒——
  /// 使用者看到的是「快好了」停在那裡不動
  final double tailSec;

  /// 每支素材轉檔以外的雜項（探測、排隊、出廠檢驗）
  final double perItemSec;

  /// 進度樣本要跑滿幾秒才拿來估倍速
  final double warmSec;

  /// 倍速的合理範圍。硬體轉檔實測 2~8 倍速；「免轉直用」那條路是
  /// 純檔案複製（30 秒的素材 1 秒就好＝30 倍速），拿它去估下一支
  /// 真的要轉的 4K 就會說「快好了」然後停在那裡
  static const _minSpeed = 0.15;
  static const _maxSpeed = 15.0;

  /// 這次執行裡「組合成」實際花掉的秒數（[noteTailSec] 記下來）。
  /// 下一次匯入就用真的數字當尾巴，不用猜
  static double learnedTailSec = 2.0;

  /// 測試用：把學到的尾巴歸零
  static void resetLearnedTail() => learnedTailSec = 2.0;

  /// 這一趟的收尾實際花了多久（跟舊值各半，一次爛樣本不會整個歪掉）
  static void noteTailSec(double sec) {
    if (!sec.isFinite || sec < 0) return;
    learnedTailSec = (learnedTailSec + sec.clamp(0.3, 20.0)) / 2;
  }

  DateTime? _start;

  /// 正在轉的那一支：開始時間、素材長度、進度
  DateTime? _curStart;
  double _curSrcSec = 0;
  double _curProgress = 0;

  /// 轉完的那些：素材秒數與牆鐘秒數各自累加
  double _doneSrcSec = 0;
  double _doneWallSec = 0;

  /// 進入「組合成」那一段的時間（尾巴從這裡開始倒數）
  DateTime? _composingAt;

  final _EtaSmoother _smooth = _EtaSmoother();

  bool get started => _start != null;

  void start() {
    _start = _clock();
    _curStart = null;
    _curSrcSec = 0;
    _curProgress = 0;
    _doneSrcSec = 0;
    _doneWallSec = 0;
    _composingAt = null;
  }

  /// 開始轉一支素材（[srcSec] ＝這支素材多長）
  void itemStart(double srcSec) {
    _start ??= _clock();
    _curStart = _clock();
    _curSrcSec = srcSec.isFinite && srcSec > 0 ? srcSec : 0;
    _curProgress = 0;
  }

  /// 這一支轉到哪了（0~1，原生端回報）
  void noteProgress(double p) {
    if (!p.isFinite) return;
    _curProgress = p.clamp(0.0, 1.0);
  }

  /// 這一支結束了（成功失敗都算：時間都花掉了）
  void itemDone() {
    final st = _curStart;
    if (st != null) {
      final wall = _sec(st);
      // 0.25 秒內就回來的不是轉檔（快取命中、平台不支援直接回）：
      // 拿它當樣本會算出幾百倍速
      if (wall >= 0.25 && _curSrcSec > 0) {
        _doneSrcSec += _curSrcSec;
        _doneWallSec += wall;
      }
    }
    _curStart = null;
    _curSrcSec = 0;
    _curProgress = 0;
  }

  /// 檔都備好了，開始組合成（遮罩的最後一段）
  void composing() => _composingAt ??= _clock();

  /// 目前量到的倍速（素材秒 ÷ 牆鐘秒）。null＝還沒有可信的樣本
  double? get speed {
    if (_doneWallSec > 0.05 && _doneSrcSec > 0) {
      return (_doneSrcSec / _doneWallSec).clamp(_minSpeed, _maxSpeed);
    }
    final st = _curStart;
    if (st == null || _curSrcSec <= 0) return null;
    final ran = _sec(st);
    if (ran < warmSec || _curProgress <= 0.005) return null;
    final v = _curProgress * _curSrcSec / ran;
    return v > 0 ? v.clamp(_minSpeed, _maxSpeed) : null;
  }

  /// 尾巴還剩多少（還沒進到組合成就是整段）
  double get _tailLeft {
    final at = _composingAt;
    if (at == null) return tailSec;
    return math.max(0.0, tailSec - _sec(at));
  }

  /// 剩下的秒數（原始估計，不平滑）。
  /// [srcSecLeft] 是「還沒備好的素材」的長度總和（含正在轉的那一支
  /// 的全長，它的進度由這裡自己扣）；[itemsLeft] 是還有幾支。
  /// null＝還估不出來（沒有倍速樣本）
  double? rawRemaining({required double srcSecLeft, required int itemsLeft}) {
    if (_start == null) return null;
    final tail = _tailLeft;
    final left = math.max(0.0, srcSecLeft - _curProgress * _curSrcSec);
    if (left <= 0.001) return tail; // 只剩收尾：不用倍速也答得出來
    final sp = speed;
    if (sp == null) return null;
    return left / sp + math.max(0, itemsLeft) * perItemSec + tail;
  }

  /// 平滑後的讀數（整數秒）；null＝估算中
  int? remainingSec({required double srcSecLeft, required int itemsLeft}) {
    final raw = rawRemaining(srcSecLeft: srcSecLeft, itemsLeft: itemsLeft);
    if (raw == null) return null;
    return _smooth.apply(raw, _clock());
  }

  /// 只有「約還要…」那一段（前面接什麼由畫面決定）
  String remainingText({required double srcSecLeft, required int itemsLeft}) =>
      _formatRemaining(
        remainingSec(srcSecLeft: srcSecLeft, itemsLeft: itemsLeft),
      );

  /// 遮罩那一行：「第 2 / 5 支 · 約還要 40 秒」
  String label({
    required int index1,
    required int total,
    required double srcSecLeft,
    required int itemsLeft,
  }) =>
      '第 $index1 / $total 支 · '
      '${remainingText(srcSecLeft: srcSecLeft, itemsLeft: itemsLeft)}';

  static String formatRemaining(int? sec) => _formatRemaining(sec);

  double _sec(DateTime from) =>
      _clock().difference(from).inMilliseconds / 1000.0;
}
