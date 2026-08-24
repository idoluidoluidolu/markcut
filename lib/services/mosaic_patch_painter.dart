import 'dart:math' as math;
import 'dart:ui' as ui;

import '../models/mosaic.dart';

/// 照片馬賽克的「唯一畫法」（跟 text_mark_painter／logo_mark_painter
/// 同一個治本思路）：照片編輯器的預覽補丁與照片匯出
///（WatermarkRenderer._drawMosaic）都直接執行這一個函式，
/// 格數、取色、模糊半徑、羽化全部只有一份，兩邊不可能走鐘。
///
/// （影片的馬賽克另一回事：預覽的合成播放器與匯出本來就共用
/// iOS 端同一段 CI 程式碼，不經過這裡。）
///
/// [srcRect]＝這一塊對應到照片上的範圍（照片像素座標）；
/// [dstRect]＝畫在 canvas 的哪裡。匯出時畫布就是照片座標，兩者相等。
void paintMosaicPatch(
  ui.Canvas canvas,
  ui.Image img,
  MosaicStyle st,
  ui.Rect srcRect,
  ui.Rect dstRect,
) {
  if (dstRect.width < 1 || dstRect.height < 1) return;
  if (st.type == 2) {
    canvas.drawRect(dstRect, ui.Paint()..color = ui.Color(st.color));
    return;
  }

  final scale = dstRect.width / srcRect.width;
  // 柔邊遮罩寬度（像素化與模糊共用同一條公式）
  final featherPx = st.feather * 0.2 * math.min(dstRect.width, dstRect.height);

  /// 把剛畫好的那一層用「中間實、邊緣淡」的遮罩收邊。
  /// 遮罩用圖層模糊而不是 MaskFilter——web 的繪圖引擎對 MaskFilter
  /// 支援不完整，會變成硬邊
  void softEdge() {
    canvas.saveLayer(
      dstRect,
      ui.Paint()
        ..blendMode = ui.BlendMode.dstIn
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: featherPx * 0.5,
          sigmaY: featherPx * 0.5,
        ),
    );
    canvas.drawRect(
      dstRect.deflate(featherPx),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    canvas.restore();
    canvas.restore();
  }

  if (st.type == 0) {
    // 真像素塊：每格取格中心那一顆像素（同步、確定性；
    // 縮小再放大的平均法要離屏 toImage，非同步又跨引擎不穩）
    final soft = featherPx >= 1;
    if (soft) canvas.saveLayer(dstRect, ui.Paint());
    final cells = (26 - 20 * st.strength).round().clamp(4, 40);
    final nx = cells;
    final ny = math.max(1, (cells * dstRect.height / dstRect.width).round());
    final cw = dstRect.width / nx;
    final ch = dstRect.height / ny;
    final paintCell = ui.Paint()..filterQuality = ui.FilterQuality.none;
    for (var iy = 0; iy < ny; iy++) {
      for (var ix = 0; ix < nx; ix++) {
        final sx = srcRect.left + (ix + 0.5) / nx * srcRect.width;
        final sy = srcRect.top + (iy + 0.5) / ny * srcRect.height;
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(
            sx.clamp(0.0, img.width - 1.0),
            sy.clamp(0.0, img.height - 1.0),
            1,
            1,
          ),
          ui.Rect.fromLTWH(
            dstRect.left + ix * cw,
            dstRect.top + iy * ch,
            cw + 0.5,
            ch + 0.5,
          ),
          paintCell,
        );
      }
    }
    if (soft) softEdge();
    return;
  }

  // 模糊：半徑以「照片解析度」為基準（跟影片匯出同公式，
  // 換張解析度不同的照片看起來一樣濃），再換算到畫布座標——
  // 預覽跟成品才是同一個濃度
  final sigma = math.max(
    2.0 * scale,
    (2 + st.strength * 18) * math.min(img.width, img.height) / 540 * scale,
  );
  // 整張圖在此座標系的位置：srcRect 對齊 dstRect
  final dstFull = ui.Rect.fromLTWH(
    dstRect.left - srcRect.left * scale,
    dstRect.top - srcRect.top * scale,
    img.width * scale,
    img.height * scale,
  );
  final soft = featherPx >= 1;
  if (soft) canvas.saveLayer(dstRect, ui.Paint());
  canvas.save();
  canvas.clipRect(dstRect);
  canvas.saveLayer(
    dstRect,
    ui.Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
  );
  canvas.drawImageRect(
    img,
    ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    dstFull,
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  canvas.restore();
  canvas.restore();
  if (soft) softEdge();
}
