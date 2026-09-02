import 'dart:async';

/// 疊加物（浮水印/文字）同步狀態機：把「內容指紋 → 烘圖 → 送原生」
/// 收成一條單通道。接線見 video_editor_screen 的 `_ovSync`。
///
/// 規則（全部就這幾條）：
/// 1. 同時只烘一版；起烘那一刻烘的一定是最新指紋。
/// 2. 結果按起烘順序套用；套用前若已有「更新的指紋」上屏（例如合成
///    重建帶進去的快照），這版直接丟掉。
/// 3. 手勢中（指紋在 [quietMs] 內變過）走快路（半解析度），兩次起烘
///    至少隔 [minGapMs]。
/// 4. 手勢停穩 [quietMs] 後恰好補一版全解析；期間不會快/全交替。
/// 5. 烘的期間指紋又變了：這版照樣上（比螢幕上的新），烘完立刻追。
class OverlaySync {
  OverlaySync({
    required this.enabled,
    required this.signature,
    required this.bake,
    required this.apply,
    this.debounceMs = 40,
    this.minGapMs = 80,
    this.quietMs = 500,
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

  final int debounceMs;
  final int minGapMs;
  final int quietMs;

  static const String empty = 'empty';

  /// 目前上屏的那一版（指紋／是不是半解析度）
  String? appliedSig;
  bool appliedFast = false;

  // 指紋每變一次 +1；套用時記下版本，晚到的舊版本就丟
  int _seq = 0;
  int _appliedSeq = 0;
  String? _seenSig;
  DateTime _changedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastStart;
  Future<void>? _inflight;
  bool _again = false;
  Timer? _timer;
  DateTime? _due;
  bool _disposed = false;

  /// 計數（診斷）：佔線略過／等停穩／丟過期／烘完追最新
  int skipBusy = 0;
  int skipHold = 0;
  int dropped = 0;
  int stale = 0;

  /// 內容可能變了：併批 [debounceMs] 後檢查。任何地方都可以隨便叫，
  /// 便宜（只排計時器）
  void request() => _armIn(debounceMs);

  /// 把最新指紋以全解析度上屏，等到完成才回來（起播前用）
  Future<void> flush() async {
    for (var i = 0; i < 4; i++) {
      final f = _inflight;
      if (f != null) await f;
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
      _changedAt = DateTime.now();
    }
    return sig;
  }

  void _armIn(int ms) {
    if (_disposed) return;
    if (ms < 0) ms = 0;
    final when = DateTime.now().add(Duration(milliseconds: ms));
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
    final sig = _observe();
    if (_inflight != null) {
      _again = true;
      skipBusy++;
      return;
    }
    final now = DateTime.now();
    final sinceChange = now.difference(_changedAt).inMilliseconds;
    final gesture = sinceChange < quietMs;
    if (sig == appliedSig) {
      if (!appliedFast) return; // 上屏的就是最新全解析：沒事
      if (gesture && !full) {
        // 還在拖、內容沒變：等停穩再補全解析（一次）
        skipHold++;
        _armIn(quietMs - sinceChange);
        return;
      }
    } else if (gesture && !full && _lastStart != null) {
      final gap = now.difference(_lastStart!).inMilliseconds;
      if (gap < minGapMs) {
        _armIn(minGapMs - gap); // 節拍：快路兩版之間至少 minGapMs
        return;
      }
    }
    final fast = !full && gesture && sig != empty;
    final seq = _seq;
    _lastStart = now;
    final task = _bakeAndApply(sig, fast, seq);
    _inflight = task;
    try {
      await task;
    } finally {
      _inflight = null;
      if (!_disposed && (_again || appliedFast)) {
        _again = false;
        _armIn(debounceMs); // 追最新／排停穩後的全解析
      }
    }
  }

  Future<void> _bakeAndApply(String sig, bool fast, int seq) async {
    final maps = sig == empty
        ? <Map<String, dynamic>>[]
        : await bake(sig, fast);
    if (_disposed || maps == null || !enabled()) return;
    if (seq < _appliedSeq || (sig == appliedSig && fast == appliedFast)) {
      dropped++; // 更新（或一模一樣）的版本已經上屏：這版作廢
      return;
    }
    if (signature() != sig) {
      stale++;
      _again = true; // 照樣先上（比螢幕上的新），烘完馬上追
    }
    if (await apply(maps, sig, fast)) {
      appliedSig = sig;
      appliedFast = fast;
      if (seq > _appliedSeq) _appliedSeq = seq;
    }
  }
}
