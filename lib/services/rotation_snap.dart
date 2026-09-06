import 'package:flutter/services.dart' show HapticFeedback;

/// 兩指旋轉的 15 度吸附：工作室、影片編輯、照片編輯共用同一套手感。
///
/// 一個手勢的生命週期：兩指張開到門檻那一刻叫 [arm]（帶領頭元素當下的
/// 角度）；之後每一格把「兩指相對起手轉了幾度」丟進 [delta]，拿回要加在
/// 每個目標底角上的角度（吸附過的）；放手叫 [end]。
///
/// 為什麼以「領頭」算一次、同一個修正量套給全部，而不是每個目標各自吸：
/// 浮水印素材的文字跟圖片一起轉時，各自吸附會把兩者的相對角度吸歪；
/// 而且同一格連判兩次，「吸住／沒吸住」會在兩個不同角度之間翻來翻去，
/// 每翻一次就震一下。
///
/// 三條規則，全是為了「純縮放時手指自然的抖動」：
/// 1. 門檻：兩指轉不到 [engageDeg] 不算旋轉，角度一動不動；一旦轉過就
///    整手勢跟著手走，不再每一格重看門檻——以前抖進抖出門檻時，角度會
///    停在上一格的殘值，畫面看起來像在抽動。
/// 2. 遲滯：離吸附點 [snapInDeg] 內黏上去，黏住後要離開超過 [snapOutDeg]
///    才脫離。黏上跟脫離同一個門檻的話，手指抖在門檻上就是黏了脫、
///    脫了黏，每一格畫面跳一下。
/// 3. 只在「換到另一個吸附點」那一刻震一下：起手時元素本來就坐著的那個
///    點不算、脫離之後又黏回同一個點也不算。
class RotationSnap {
  RotationSnap({
    this.step = 15,
    this.engageDeg = 3,
    this.snapInDeg = 4,
    this.snapOutDeg = 8,
  });

  /// 每幾度一個吸附點
  final double step;

  /// 兩指要轉超過幾度才算旋轉
  final double engageDeg;

  /// 離吸附點幾度內黏上去
  final double snapInDeg;

  /// 黏住之後要離開幾度才脫離（要比 [snapInDeg] 大才有遲滯）
  final double snapOutDeg;

  double _base = 0;
  bool _engaged = false;

  /// 現在黏在哪個吸附點（正規化到 0~360；null＝自由轉動）
  double? _snappedAt;

  /// 上一次震動時黏的吸附點（正規化）；起手精準坐著的那個點先記進來
  double? _hapticAt;

  /// 這一手的角度真的動過了（離開過起手的刻度、或起手就不在刻度上）
  bool _moved = false;
  double? _guide;

  /// 正在黏住的吸附點角度（畫輔助線用）。沒轉過門檻、自由轉動中、
  /// 或只是抖動而從沒離開起手那個刻度時都是 null——純縮放時畫面上
  /// 憑空多一條線跟「0°」，人會以為自己轉到了什麼
  double? get guide => _guide;

  /// 這一手已經轉過門檻了
  bool get engaged => _engaged;

  /// 兩指張開到門檻那一刻：記領頭元素當下的角度
  void arm(double leadBaseDeg) {
    _base = wrapDeg(leadBaseDeg);
    _engaged = false;
    _guide = null;
    final near = _nearest(_base);
    final d = _dist(_base, near);
    _snappedAt = d <= snapInDeg ? _norm(near) : null;
    // 本來就精準坐在刻度上的（預設 0 度、上一手吸過的）不用震；
    // 離刻度一兩度（滑桿拉出來的）被磁鐵拉上去時還是要震一下，
    // 人才知道角度被動過
    _hapticAt = d < 0.01 ? _snappedAt : null;
    _moved = _hapticAt == null;
  }

  /// 這一格兩指相對起手轉了 [dDeg] 度 → 回傳要加在每個目標底角上的角度。
  /// 沒轉過門檻回 0（角度留在底值）
  double delta(double dDeg) {
    if (!_engaged) {
      if (dDeg.abs() <= engageDeg) return 0;
      _engaged = true;
    }
    final raw = wrapDeg(_base + dDeg);
    final at = _snappedAt;
    if (at != null) {
      if (_dist(raw, at) <= snapOutDeg) return _hold(at);
      _snappedAt = null;
      _moved = true;
    }
    final near = _nearest(raw);
    if (_dist(raw, near) <= snapInDeg) {
      _snappedAt = _norm(near);
      return _hold(_snappedAt!);
    }
    _moved = true;
    _guide = null;
    return dDeg;
  }

  /// 黏在 [detent] 上：跟上次震的時候不同的刻度才震；真的動過才畫輔助線
  double _hold(double detent) {
    if (_hapticAt != detent) {
      _hapticAt = detent;
      HapticFeedback.selectionClick();
    }
    _guide = _moved ? wrapDeg(detent) : null;
    return wrapDeg(detent - _base);
  }

  /// 放手：清掉這一手的狀態
  void end() {
    _engaged = false;
    _snappedAt = null;
    _hapticAt = null;
    _moved = false;
    _guide = null;
  }

  /// 收到 -180~180
  static double wrapDeg(double v) {
    var x = v;
    while (x > 180) {
      x -= 360;
    }
    while (x < -180) {
      x += 360;
    }
    return x;
  }

  double _nearest(double deg) => (deg / step).roundToDouble() * step;

  static double _norm(double deg) => ((deg % 360) + 360) % 360;

  static double _dist(double a, double b) => wrapDeg(a - b).abs();
}
