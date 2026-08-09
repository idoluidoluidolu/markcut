import 'package:shared_preferences/shared_preferences.dart';

/// 匯出速度的學習與預估。
///
/// 「這支影片要跑多久」沒辦法從規格算出來——同樣的片子在有硬體編碼器的
/// 手機上跟在模擬器上差好幾倍。所以改成量測：每次匯出完把實際速度記下來，
/// 下次拿來估。第一次沒資料就用保守的預設值，並且說明那是粗估。
class ExportSpeed {
  /// 每百萬像素、每秒輸出，要花幾秒 wall-clock。
  /// 例：1080p(2.07MP) 的 10 秒片 × 這個係數 = 預估秒數
  static const _key = 'export_secs_per_mpx_sec_v1';

  /// 還沒有量測資料時的保守預設（中階手機硬體編碼大約這個量級）
  static const _fallback = 0.18;

  static double? _cached;

  static Future<double> factor() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    return _cached = prefs.getDouble(_key) ?? _fallback;
  }

  /// 這次匯出實際花了多久 → 更新係數。
  /// 用指數移動平均，單次異常（背景有別的 App 在吃 CPU）不會把估值帶歪
  static Future<void> record({
    required int outW,
    required int outH,
    required double outSeconds,
    required Duration elapsed,
  }) async {
    final work = outW * outH / 1000000.0 * outSeconds;
    if (work <= 0.01 || elapsed.inMilliseconds < 500) return;
    final measured = elapsed.inMilliseconds / 1000.0 / work;
    // 上限放寬到 60：卡在軟體編碼的舊機器實測可能超過 20，
    // 擋掉的話估值永遠學不到、每次都估太快
    if (!measured.isFinite || measured <= 0 || measured > 60) return;
    final prev = await factor();
    _cached = prev * 0.6 + measured * 0.4;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_key, _cached!);
  }

  static Future<bool> hasMeasured() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_key);
  }

  /// 預估秒數
  static Future<double> estimate({
    required int outW,
    required int outH,
    required double outSeconds,
  }) async {
    final f = await factor();
    return outW * outH / 1000000.0 * outSeconds * f;
  }
}

/// 秒數 → 「約 1 分 20 秒」這種給人看的字串
String fmtDuration(double secs) {
  if (secs < 1) return '不到 1 秒';
  final s = secs.round();
  if (s < 60) return '$s 秒';
  final m = s ~/ 60;
  final r = s % 60;
  if (m < 60) return r == 0 ? '$m 分' : '$m 分 $r 秒';
  final h = m ~/ 60;
  return '$h 小時 ${m % 60} 分';
}
