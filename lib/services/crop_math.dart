import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

/// 影片裁切的換算。
///
/// 影片不是真的裁成一張新圖——那要重新編碼整段。裁切框改成換算成片段的
/// 縮放與位移（scale / px / py）：預覽、合成播放器、原生匯出、FFmpeg
/// 匯出本來就都吃這三個值，所以裁切是零成本的，而且隨時調得回來。
///
/// 座標一律用「畫布寬 = canvasAspect、畫布高 = 1」這組單位，跟預覽的
/// layerBox 與匯出的算法同一套。

/// 素材貼合畫布之後佔的寬高
(double, double) fitInCanvas(double srcAspect, double canvasAspect) =>
    srcAspect >= canvasAspect
    ? (canvasAspect, canvasAspect / srcAspect)
    : (srcAspect, 1.0);

/// 裁切框（0~1，素材座標）→ 片段的縮放與位移。
///
/// 框「放得進畫布」就好，不是「填滿畫布」：兩個方向各自需要多大，
/// 取小的那個。填滿的話框的長邊會被畫布切掉——使用者框了什麼卻看不到
/// 全部，而且「整張都框起來」會變成自動放大填滿，等於什麼都沒改卻
/// 被裁了一刀
({double scale, double px, double py}) cropToTransform(
  Rect crop,
  double srcAspect,
  double canvasAspect,
) {
  final (fw, fh) = fitInCanvas(srcAspect, canvasAspect);
  final w = math.max(0.01, crop.width);
  final h = math.max(0.01, crop.height);
  final s = math.min(canvasAspect / (w * fw), 1 / (h * fh));
  return (
    scale: s,
    px: 0.5 - ((crop.left + w / 2) - 0.5) * fw * s / canvasAspect,
    py: 0.5 - ((crop.top + h / 2) - 0.5) * fh * s,
  );
}

/// 反過來：現在的縮放位移 → 裁切框。
/// 重新開啟裁切畫面時要停在原本的位置
Rect transformToCrop(
  double scale,
  double px,
  double py,
  double srcAspect,
  double canvasAspect,
) {
  final (fw, fh) = fitInCanvas(srcAspect, canvasAspect);
  final s = scale <= 0 ? 1.0 : scale;
  final w = math.min(1.0, canvasAspect / (fw * s));
  final h = math.min(1.0, 1 / (fh * s));
  final cx = 0.5 + canvasAspect * (0.5 - px) / (fw * s);
  final cy = 0.5 + (0.5 - py) / (fh * s);
  return Rect.fromLTWH(
    (cx - w / 2).clamp(0.0, 1 - w),
    (cy - h / 2).clamp(0.0, 1 - h),
    w,
    h,
  );
}

/// 左右翻轉一個 0~1 的框（給鏡像的片段用）。
///
/// 裁切底圖抓的是「未鏡像」的原始畫面，但片段實際顯示是翻過的：
/// 內容在來源的 x，顯示時在 1-x。框在兩套座標之間換的就是這一下，
/// 來回各翻一次（翻兩次＝原樣）
Rect flipRectX(Rect r) =>
    Rect.fromLTWH(1 - r.left - r.width, r.top, r.width, r.height);

// ── 裁切畫面的雙指縮放 ──────────────────────────────────────────────
//
// 下面兩個函式都在「畫面座標」上算，每次都從起手的框 [start] 算，不累乘
// （累乘會飄）。極限三件事一致：框不出圖（[view]）、每邊不小於
// [minSide]、永遠不反轉。

/// 自由模式：兩指各自拉多遠，框那一側的邊就走多遠。
///
/// [fingersStart]／[fingers] 是「把所有手指包起來的方框」起手時與現在的
/// 樣子。寬跟著方框的寬變、高跟著方框的高變、中心跟著方框的中心走——
/// 沒撞到極限時這正好是「左邊跟左手指、右邊跟右手指、上下同理」：
/// 水平拉開只變寬、垂直拉開只變高、斜拉兩軸各自照手指走、兩指一起移
/// 就是搬。
///
/// 用「位移」不用「比例」：兩指擺得近乎水平時，垂直方向的起始距離只有
/// 幾個像素，用比例（ScaleUpdateDetails.verticalScale 那種）會把手指
/// 一點點抖動放大成好幾倍，框就亂跳；完全水平時比例根本算不出來。
Rect pinchCropFree({
  required Rect start,
  required Rect view,
  required double minSide,
  required Rect fingersStart,
  required Rect fingers,
}) {
  final w = _side(
    start.width + (fingers.width - fingersStart.width),
    minSide,
    view.width,
  );
  final h = _side(
    start.height + (fingers.height - fingersStart.height),
    minSide,
    view.height,
  );
  final c = start.center + (fingers.center - fingersStart.center);
  return _keepInView(Rect.fromCenter(center: c, width: w, height: h), view);
}

/// 等比：兩指距離變成 [scale] 倍，框就變 [scale] 倍，繞著起手時的焦點
/// [focal]（焦點在起手框裡的相對位置不變，所以手指按著的那塊內容留在
/// 指尖底下），兩指中點移了 [pan] 框就跟著移。
///
/// [ratio] 有值＝鎖比例：寬決定一切，最小是「兩邊都不小於 [minSide]」、
/// 最大是「兩邊都不出圖」，所以捏到底比例也不會破。null＝自由模式
/// 但拿不到手指位置時（觸控板的捏合）的退路，兩軸各自夾。
Rect pinchCropUniform({
  required Rect start,
  required Rect view,
  required double minSide,
  required double? ratio,
  required double scale,
  required Offset focal,
  required Offset pan,
}) {
  final double w;
  final double h;
  if (ratio == null) {
    w = _side(start.width * scale, minSide, view.width);
    h = _side(start.height * scale, minSide, view.height);
  } else {
    w = _side(
      start.width * scale,
      math.max(minSide, minSide * ratio),
      math.min(view.width, view.height * ratio),
    );
    h = w / ratio;
  }
  final rel = Offset(
    start.width == 0 ? 0.5 : (focal.dx - start.left) / start.width,
    start.height == 0 ? 0.5 : (focal.dy - start.top) / start.height,
  );
  return _keepInView(
    Rect.fromLTWH(
      focal.dx + pan.dx - rel.dx * w,
      focal.dy + pan.dy - rel.dy * h,
      w,
      h,
    ),
    view,
  );
}

/// 邊長夾在 [lo, hi]；圖比最小邊還小的極端情況以圖為準
double _side(double v, double lo, double hi) => math.min(math.max(v, lo), hi);

/// 框整個推回圖裡（大小不變，只搬）
Rect _keepInView(Rect r, Rect view) => Rect.fromLTWH(
  r.left.clamp(view.left, math.max(view.left, view.right - r.width)),
  r.top.clamp(view.top, math.max(view.top, view.bottom - r.height)),
  r.width,
  r.height,
);
