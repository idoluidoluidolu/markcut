import 'dart:math' as math;

/// GIF 頁選取範圍的規矩。
///
/// 起訖點只有一個入口：指針移到想要的位置，按「設起點」／「設終點」。
/// 把手不吃觸控（使用者指定：拉桿無法靠觸控拖曳，頭尾一律靠自己按
/// 起點終點），所以這裡沒有「這一下要動誰」的命中判定，只有「按下去
/// 之後範圍變成什麼」。
///
/// 按下去永遠算數（使用者指定：起點設在終點之後「改成不會擋，自動把
/// 長度橫移過去，終點自動改後面就好」）：
///   - 指針還在另一端的正確側：只動這一端，另一端不動。
///   - 指針跑到另一端上或另一側：整段範圍平移過去——長度維持原本的
///     長度，另一端跟著搬。碰到影片頭尾搬不動了，長度才縮，但最短
///     不低於 [kTrimMinGap]。
/// 以前是「不算數、跳提示」，使用者嫌它擋路。純數學、沒有 Flutter
/// 相依，可以直接測

/// 範圍最短這麼多秒
const double kTrimMinGap = 0.2;

/// 一段選取範圍（秒）
typedef TrimRange = ({double start, double end});

/// 指針在 [t]、目前範圍 [start]~[end]、影片總長 [dur]：按「設起點」
/// 之後的範圍
TrimRange trimSetStart(
  double t,
  double start,
  double end,
  double dur, {
  double minGap = kTrimMinGap,
}) {
  final len = math.max(minGap, end - start);
  // 起點最右只能到「還留得下最短長度」的地方
  final ns = t.clamp(0.0, math.max(0.0, dur - minGap)).toDouble();
  if (ns <= end - minGap) return (start: ns, end: end);
  // 指針在終點上或右邊：整段搬過去，長度不變；尾端頂到影片結尾就縮
  final ne = math.min(dur, ns + len);
  return (start: ns, end: math.max(ne, math.min(dur, ns + minGap)));
}

/// 指針在 [t]、目前範圍 [start]~[end]、影片總長 [dur]：按「設終點」
/// 之後的範圍（跟 [trimSetStart] 對稱：跑到起點上或左邊就整段往前搬）
TrimRange trimSetEnd(
  double t,
  double start,
  double end,
  double dur, {
  double minGap = kTrimMinGap,
}) {
  final len = math.max(minGap, end - start);
  // 終點最左只能到「還留得下最短長度」的地方
  final ne = t.clamp(math.min(dur, minGap), math.max(0.0, dur)).toDouble();
  if (ne >= start + minGap) return (start: start, end: ne);
  // 指針在起點上或左邊：整段往前搬，長度不變；頭端頂到 0 就縮
  final ns = math.max(0.0, ne - len);
  return (start: math.min(ns, math.max(0.0, ne - minGap)), end: ne);
}
