import 'dart:math' as math;
import 'dart:ui' show Rect;

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
/// 框會填滿畫布：兩個方向各自需要多大，取大的那個
({double scale, double px, double py}) cropToTransform(
  Rect crop,
  double srcAspect,
  double canvasAspect,
) {
  final (fw, fh) = fitInCanvas(srcAspect, canvasAspect);
  final w = math.max(0.01, crop.width);
  final h = math.max(0.01, crop.height);
  final s = math.max(canvasAspect / (w * fw), 1 / (h * fh));
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
