import 'dart:async';

/// 疊加物（浮水印/文字）同步狀態機：把「內容指紋 → 烘圖 → 送原生」
/// 收成一條單通道。接線見 video_editor_screen 的 `_ovSync`。
///
/// 規則（全部就這幾條）：
/// 1. 閒置後的第一次變更立刻檢查（下一輪事件迴圈就起烘，不等併批）；
///    [debounceMs] 內剛檢查過才併批。起烘那一刻烘的一定是最新指紋。
/// 2. 快路同時只烘一版。全解析在途、內容又變了：全解析退到背景
///    （烘完照序號規則上或丟），新內容的快路不等它。
/// 3. 結果按送出順序上屏（通道有序）；送出前若已有「更新的指紋」送出
///    或上屏（例如合成重建帶進去的快照），這版直接丟掉。
/// 4. 手勢中（[gestureActive] 回 true，或指紋在 [quietMs] 內變過）走快路
///    （半解析度），兩次快路起烘至少隔 [minGapMs]。
/// 5. 手勢停穩 [quietMs] 後恰好補一版全解析；期間不會快/全交替。
///    [gestureActive] 回 true 的期間一律不起烘全解析。
/// 6. 烘的期間指紋又變了：這版照樣上（比螢幕上的新），烘完立刻追；
///    螢幕上已經是最新內容的話這版就丟（上了會閃回舊內容）。
class OverlaySync {
  OverlaySync({
    required this.enabled,
    required this.signature,
    required this.bake,
    required this.apply,
    this.gestureActive,
    this.debounceMs = 40,
    this.minGapMs = 80,
    this.quietMs = 500,
    this.now = DateTime.now,
  });

  /// 現在有沒有收件方（沒有＝什麼都不做）
  final bool Function() enabled;

  /// 目前內容指紋；[empty] 代表沒有內容（不烘、送空清單）
  final String Function() signature;

  /// 烘 [sig] 這一版（[fast]＝半解析度）。回 null＝作廢（畫面已卸載）
  final Future<List<Map<String, dynamic>>?> Function(String sig, bool fast)
  bake;

  /// 送到原生；回 false＝被拒收（不記為已上屏）
  final Future<bool> Function(
    List<Map<String, dynamic>> maps,
    String sig,
    bool fast,
  )
  apply;

  /// 呼叫端明確知道「手勢還在進行」（面板滑桿按著）。回 true 的期間
  /// 一律走快路、全解析等放手——不靠「指紋 [quietMs] 內變過」推測：
  /// 拖到一半停手半秒（換方向、看一下）就會被推測成停穩而起烘
  /// 全解析（1080 PNG 幾百毫秒），接著再動就被它擋住（實機回饋：
  /// 拉到一半硬停、過一會兒才跟上）。沒給＝只靠指紋推測
  final bool Function()? gestureActive;

  final int debounceMs;
  final int minGapMs;
  final int quietMs;

  /// 時鐘（測試注入假時鐘用）
  final DateTime Function() now;

  static const String empty = 'empty';

  /// 目前上屏的那一版（指紋／是不是半解析度）
  String? appliedSig;
  bool appliedFast = false;

  // 指紋每變一次 +1；送出時記下版本（通道有序＝送出順序就是上屏
  // 順序），晚烘完的舊版本就丟
  int _seq = 0;
  int _appliedSeq = 0;
  // 送出計數：回來時只有「最後送的那版」才能記為已上屏
  int _sendN = 0;
  String? _seenSig;
  DateTime _changedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastRun = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastFastStart;
  // 前景在途的那版（快或全）＋退到背景的全解析（最多一版）
  Future<void>? _inflight;
  String? _inflightSig;
  bool _inflightFull = false;
  Future<void>? _bg;
  bool _again = false;
  Timer? _timer;
  DateTime? _due;
  bool _disposed = false;

  /// 計數（診斷）：佔線略過／等停穩／丟過期／烘完追最新／全解析退背景
  int skipBusy = 0;
  int skipHold = 0;
  int dropped = 0;
  int stale = 0;
  int demoted = 0;

  /// 內容可能變了。任何地方都可以隨便叫，便宜（只排計時器）。
  /// 閒置後的第一次變更不等併批（點一格九宮格的延遲不該從
  /// [debounceMs] 起跳）；[debounceMs] 內剛檢查過才併批——連續
  /// setState 一輪只檢查一次，指紋（jsonEncode）不會被算爆
  void request() {
    if (_disposed) return;
    final since = now().difference(_lastRun).inMilliseconds;
    _armIn(since >= debounceMs ? 0 : debounceMs - since);
  }

  /// 把最新指紋以全解析度上屏，等到完成才回來（起播前用）
  Future<void> flush() async {
    for (var i = 0; i < 4; i++) {
      final f = _inflight;
      if (f != null) await f;
      final g = _bg;
      if (g != null) await g;
      if (_disposed || !enabled()) return;
      if (appliedSig == signature() && !appliedFast) return;
      await _run(full: true);
    }
  }

  /// 合成重建完成：新合成帶著 [appliedSig] 這一版（'off'＝沒帶）。
  /// 之後 [request] 會補送最新版
  void reset({required String appliedSig}) {
    final sig = _observe();
    this.appliedSig = appliedSig;
    appliedFast = false;
    if (appliedSig == sig) _appliedSeq = _seq;
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }

  String _observe() {
    final sig = signature();
    if (sig != _seenSig) {
      _seenSig = sig;
      _seq++;
      _changedAt = now();
    }
    return sig;
  }

  void _armIn(int ms) {
    if (_disposed) return;
    if (ms < 0) ms = 0;
    final when = now().add(Duration(milliseconds: ms));
    // 已經排了更早（或同時）的就不動它
    if ((_timer?.isActive ?? false) &&
        _due != null &&
        !_due!.isAfter(when)) {
      return;
    }
    _timer?.cancel();
    _due = when;
    _timer = Timer(Duration(milliseconds: ms), () {
      _due = null;
      unawaited(_run());
    });
  }

  Future<void> _run({bool full = false}) async {
    if (_disposed || !enabled()) return;
    _lastRun = now();
    final sig = _observe();
    if (_inflight != null) {
      if (!full &&
          _inflightFull &&
          _inflightSig != sig &&
          sig != empty &&
          _bg == null) {
        // 在途的是全解析、內容又變了：它退到背景（烘完照序號規則
        // 上或丟），新內容的快路不等它。不然停穩後那版 1080 PNG
        // （幾百毫秒）會把緊接著的下一下點格／下一段拖動整個卡住
        // （實機回饋：九宮格不及時、拉到一半硬停才跟上）
        _bg = _inflight;
        _inflight = null;
        demoted++;
      } else {
        _again = true;
        skipBusy++;
        return;
      }
    }
    final t = now();
    final sinceChange = t.difference(_changedAt).inMilliseconds;
    final held = gestureActive?.call() ?? false;
    final gesture = held || sinceChange < quietMs;
    if (sig == appliedSig) {
      if (!appliedFast) return; // 上屏的就是最新全解析：沒事
      if (gesture && !full) {
        // 還在拖、內容沒變：等停穩再補全解析（一次）
        skipHold++;
        _armIn(held ? quietMs : quietMs - sinceChange);
        return;
      }
    } else if (gesture && !full && _lastFastStart != null) {
      final gap = t.difference(_lastFastStart!).inMilliseconds;
      if (gap < minGapMs) {
        _armIn(minGapMs - gap); // 節拍：快路兩版之間至少 minGapMs
        return;
      }
    }
    final fast = !full && gesture && sig != empty;
    if (!fast && _bg != null) {
      // 全解析一次一版：背景那版烘完再說（烘完會再排一次）
      _again = true;
      skipBusy++;
      return;
    }
    final seq = _seq;
    if (fast) _lastFastStart = t;
    final task = _bakeAndApply(sig, fast, seq);
    _inflight = task;
    _inflightSig = sig;
    _inflightFull = !fast;
    try {
      await task;
    } finally {
      if (identical(_bg, task)) {
        _bg = null;
      } else if (identical(_inflight, task)) {
        _inflight = null;
      }
      if (!_disposed && (_again || appliedFast)) {
        final chase = _again;
        _again = false;
        // 追最新不等併批（節拍由 minGapMs 管）／排停穩後的全解析
        _armIn(chase ? 0 : debounceMs);
      }
    }
  }

  Future<void> _bakeAndApply(String sig, bool fast, int seq) async {
    final maps = sig == empty
        ? <Map<String, dynamic>>[]
        : await bake(sig, fast);
    if (_disposed || maps == null || !enabled()) return;
    // 更新的版本已經送出、或同一版已經上屏而這版沒有更好（螢幕上
    // 已是全解析／這版也只是半解析——例如合成重建把它烘進去了）：作廢
    if (seq < _appliedSeq || (sig == appliedSig && (!appliedFast || fast))) {
      dropped++;
      return;
    }
    final cur = signature();
    if (cur != sig) {
      if (cur == appliedSig) {
        // 螢幕上已經是最新內容（例如退到背景的全解析烘完時，使用者
        // 已經點回原來那格）：過期版上了只會閃回舊內容
        dropped++;
        return;
      }
      stale++;
      _again = true; // 照樣先上（比螢幕上的新），烘完馬上追
    }
    // 送出順序＝上屏順序：起送就記序號，晚烘完的舊版本在上面那條被丟
    if (seq > _appliedSeq) _appliedSeq = seq;
    final n = ++_sendN;
    // 回來時只有「最後送的那版」能記為已上屏——送出後又送了更新的
    // 一版的話，螢幕上是那一版，由它自己回來記
    if (await apply(maps, sig, fast) && n == _sendN) {
      appliedSig = sig;
      appliedFast = fast;
    }
  }
}
