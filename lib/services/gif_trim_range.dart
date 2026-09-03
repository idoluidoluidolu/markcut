import 'dart:math' as math;

/// GIF 頁選取範圍的規矩。
///
/// 起訖點只有一個入口：指針移到想要的位置，按「設起點」／「設終點」。
/// 把手不吃觸控了（使用者指定：拉桿無法靠觸控拖曳，頭尾一律靠自己
/// 按起點終點），所以這裡不再有「這一下要動誰」的命中判定，只剩
/// 「按下去這一下算不算數」。
///
/// 算不算數就回新的秒數、不算就回 null——不偷偷夾回去：按了鈕卻換來
/// 一個自己沒選的位置，看起來就像按鈕壞了（把手時代的老問題就是
/// 「動了但不是我要的」）。不成立時由呼叫端出提示說清楚為什麼。
/// 純數學、沒有 Flutter 相依，可以直接測

/// 範圍最短這麼多秒
const double kTrimMinGap = 0.2;

/// 指針在 [t]、目前終點在 [end]：這一下「設起點」的新起點。
/// 指針跑到終點上或右邊（剩不到 [minGap]）就不算數，回 null
double? trimStartAt(double t, double end, {double minGap = kTrimMinGap}) {
  final v = math.max(0.0, t);
  return v > end - minGap ? null : v;
}

/// 指針在 [t]、目前起點在 [start]、影片總長 [dur]：這一下「設終點」的
/// 新終點。指針跑到起點上或左邊（剩不到 [minGap]）就不算數，回 null
double? trimEndAt(
  double t,
  double start,
  double dur, {
  double minGap = kTrimMinGap,
}) {
  final v = math.min(t, dur);
  return v < start + minGap ? null : v;
}
