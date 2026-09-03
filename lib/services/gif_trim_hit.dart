import 'dart:math' as math;

/// GIF 頁修剪條的命中判定：一次橫向拖曳要動誰。
///
/// 兩個把手各有 64pt 熱區、播放頭 36pt——範圍縮到零點幾秒時三個熱區
/// 整個疊在一起，靠 Stack 的疊放順序決定誰接到手勢，結果就是
/// 「把手拉近之後再也拉不開」：最上層永遠是終點把手，往左拉被夾在
/// start+0.2 動不了；停手後播放頭又剛好停在起點上，把起點把手整根
/// 蓋住（實測回報：拉到 0.2 秒就卡死）。
///
/// 這裡改成看落點：落在直條上就是那根；兩根貼在一起分不出來，
/// 就看第一下的方向——往左＝動起點、往右＝動終點（貼在一起時兩個
/// 方向都是「拉開」）。純幾何、沒有 Flutter 相依，可以直接測
enum TrimTarget {
  start,
  end,

  /// 兩根把手疊在一起：等第一下的方向再決定（見 [TrimHit.byDirection]）
  either,
  playhead,

  /// 空白處：點哪跳哪、拖了就是速覽
  background,
}

/// 修剪條上的命中幾何（單位：修剪條的 px，x 軸）
abstract final class TrimHit {
  /// 把手熱區：直條兩側各這麼寬（實測 44 太難按，加寬到 64）
  static const double handleReach = 32;

  /// 琥珀直條的寬度。起點直條貼在範圍內緣 [xs, xs+13]、
  /// 終點在 [xe-13, xe]，跟編輯器片段的內側雙把手同一個位置關係
  static const double barWidth = 13;

  /// 直條再往外這麼多都算「核心」：落在核心上一定是要拉把手，
  /// 就算播放頭剛好停在同一個位置（停手後它永遠停在把手上）
  static const double coreSlack = 10;

  /// 播放頭兩側各這麼寬（36pt 觸控區）
  static const double playheadReach = 18;

  /// [x]：落點；[xs]／[xe]：起點／終點把手的 x（範圍的內緣）；
  /// [xp]：播放頭的 x（null＝沒有播放頭可拖）
  static TrimTarget pick({
    required double x,
    required double xs,
    required double xe,
    double? xp,
  }) {
    // 兩根把手的熱區疊在一起：外側各歸各的、中間看方向。
    // 播放頭在這裡不搶——範圍只剩幾格時滑指針沒有意義，
    // 使用者要的是把範圍拉開
    if (xe - xs <= 2 * handleReach) {
      if (x < xs - handleReach || x > xe + handleReach) {
        return _playheadOrBackground(x, xp);
      }
      if (xe - xs < barWidth) {
        // 兩根直條疊成一坨，坨上分不出來：看第一下的方向
        if (x >= xe - barWidth && x <= xs + barWidth) return TrimTarget.either;
        return x < xs ? TrimTarget.start : TrimTarget.end;
      }
      if (x >= xs && x <= xs + barWidth) return TrimTarget.start;
      if (x >= xe - barWidth && x <= xe) return TrimTarget.end;
      if (x < xs) return TrimTarget.start;
      if (x > xe) return TrimTarget.end;
      return TrimTarget.either; // 兩根直條中間
    }

    // 離得夠遠：把手（含外圍熱區）一律優先於播放頭。
    // 播放頭停手後永遠停在把手上（GIF 模式指針只在範圍內動），
    // 讓它排在把手外圍之前＝從把手外側去抓抓到的是指針、範圍不動
    //（實機回報：拖好幾次拖不到）。外側給得比內側寬——要拉開範圍
    // 的手指本來就是從外面往外拉
    if (x >= xs - handleReach && x <= xs + barWidth + coreSlack) {
      return TrimTarget.start;
    }
    if (x >= xe - barWidth - coreSlack && x <= xe + handleReach) {
      return TrimTarget.end;
    }
    if (xp != null && (x - xp).abs() <= playheadReach) {
      return TrimTarget.playhead;
    }
    return TrimTarget.background;
  }

  static TrimTarget _playheadOrBackground(double x, double? xp) =>
      xp != null && (x - xp).abs() <= playheadReach
      ? TrimTarget.playhead
      : TrimTarget.background;

  /// 落點分不出來時看第一下的方向：往左＝起點、往右＝終點；
  /// 沒動就繼續等
  static TrimTarget byDirection(double dx) => dx < 0
      ? TrimTarget.start
      : dx > 0
      ? TrimTarget.end
      : TrimTarget.either;
}

/// 範圍最短這麼多秒
const double kTrimMinGap = 0.2;

/// 起點的夾限：只擋「往內」（不能越過終點減最短長度），往外永遠拉得動
double clampTrimStart(double t, double end, {double minGap = kTrimMinGap}) =>
    t.clamp(0.0, math.max(0.0, end - minGap));

/// 終點的夾限：同上，另外不能超過總長
double clampTrimEnd(
  double t,
  double start,
  double dur, {
  double minGap = kTrimMinGap,
}) => t.clamp(math.min(dur, start + minGap), math.max(0.0, dur));
