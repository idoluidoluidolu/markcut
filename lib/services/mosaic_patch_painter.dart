import 'dart:math' as math;
import 'dart:ui' as ui;

import '../models/mosaic.dart';

/// 照片馬賽克的「唯一畫法」（跟 text_mark_painter／logo_mark_painter
/// 同一個治本思路）：照片編輯器的預覽補丁與照片匯出
///（WatermarkRenderer._drawMosaic）都直接執行這裡的函式，
/// 格數、取色、模糊半徑、羽化全部只有一份，兩邊不可能走鐘。
///
/// （影片的馬賽克另一回事：預覽的合成播放器與匯出本來就共用
/// iOS 端同一段 CI 程式碼，不經過這裡。）
///
/// [srcRect]＝這一塊對應到照片上的範圍（照片像素座標）；
/// [dstRect]＝畫在 canvas 的哪裡。匯出時畫布就是照片座標，兩者相等。

/// 原始效果（像素化或模糊），不含收邊遮罩
void _paintEffect(
  ui.Canvas canvas,
  ui.Image img,
  MosaicStyle st,
  ui.Rect srcRect,
  ui.Rect dstRect,
) {
  final scale = dstRect.width / srcRect.width;

  if (st.type == 0) {
    // 真像素塊：每格取格中心那一顆像素（同步、確定性；
    // 縮小再放大的平均法要離屏 toImage，非同步又跨引擎不穩）
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
}

/// 方形補丁
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
  // 柔邊遮罩寬度（像素化與模糊共用同一條公式）
  final featherPx = st.feather * 0.2 * math.min(dstRect.width, dstRect.height);
  if (featherPx < 1) {
    _paintEffect(canvas, img, st, srcRect, dstRect);
    return;
  }
  // 真羽化：效果先畫進一層，再用「內縮＋霧化」的白色方塊當
  // alpha 遮罩（dstIn），邊緣平滑淡出。遮罩用圖層模糊而不是
  // MaskFilter——web 的繪圖引擎對 MaskFilter 支援不完整會硬邊
  canvas.saveLayer(dstRect, ui.Paint());
  _paintEffect(canvas, img, st, srcRect, dstRect);
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

/// 筆刷筆畫的外框（照片像素座標）：點的包圍盒外推「半個筆刷＋
/// 羽化尾巴」。預覽跟匯出都用這一個算，補丁範圍才一致
ui.Rect strokeBoundsPx(List<ui.Offset> pts, double brushPx, double featherPx) {
  var l = pts.first.dx, t = pts.first.dy, r = l, b = t;
  for (final p in pts) {
    l = math.min(l, p.dx);
    t = math.min(t, p.dy);
    r = math.max(r, p.dx);
    b = math.max(b, p.dy);
  }
  return ui.Rect.fromLTRB(l, t, r, b).inflate(brushPx / 2 + featherPx + 2);
}

/// 筆刷筆畫的柔邊寬度（相對筆刷粗細；方形版是相對補丁大小）
double strokeFeatherPx(MosaicStyle st, double brushPx) =>
    st.feather * 0.5 * brushPx;

/// 筆刷筆畫：效果鋪滿 [dstRect]，再用「筆畫本身」當 alpha 遮罩。
/// [srcPts]／[srcBrush]／[srcRect] 都是照片像素座標；
/// 匯出時 dstRect==srcRect，預覽時等比縮到畫布
void paintMosaicStroke(
  ui.Canvas canvas,
  ui.Image img,
  MosaicStyle st,
  List<ui.Offset> srcPts,
  double srcBrush,
  ui.Rect srcRect,
  ui.Rect dstRect,
) {
  if (srcPts.isEmpty || dstRect.width < 1 || dstRect.height < 1) return;
  final scale = dstRect.width / srcRect.width;
  final brushPx = srcBrush * scale;
  final featherPx = strokeFeatherPx(st, brushPx);

  canvas.saveLayer(dstRect, ui.Paint());
  if (st.type == 2) {
    canvas.drawRect(dstRect, ui.Paint()..color = ui.Color(st.color));
  } else {
    _paintEffect(canvas, img, st, srcRect, dstRect);
  }

  // 遮罩＝筆畫：圓頭圓角的粗線；羽化＝遮罩層整個霧化，
  // 線寬先收掉羽化寬度，暈開後粗細才不變
  ui.Offset toDst(ui.Offset p) => ui.Offset(
    dstRect.left + (p.dx - srcRect.left) * scale,
    dstRect.top + (p.dy - srcRect.top) * scale,
  );
  final mask = ui.Paint()..blendMode = ui.BlendMode.dstIn;
  if (featherPx >= 1) {
    mask.imageFilter = ui.ImageFilter.blur(
      sigmaX: featherPx * 0.5,
      sigmaY: featherPx * 0.5,
    );
  }
  canvas.saveLayer(dstRect, mask);
  final lineW = math.max(1.0, brushPx - (featherPx >= 1 ? featherPx : 0));
  if (srcPts.length == 1) {
    canvas.drawCircle(
      toDst(srcPts.first),
      lineW / 2,
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
  } else {
    final path = ui.Path()
      ..moveTo(toDst(srcPts.first).dx, toDst(srcPts.first).dy);
    for (final p in srcPts.skip(1)) {
      final d = toDst(p);
      path.lineTo(d.dx, d.dy);
    }
    canvas.drawPath(
      path,
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = lineW
        ..strokeCap = ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round
        ..color = const ui.Color(0xFFFFFFFF),
    );
  }
  canvas.restore();
  canvas.restore();
}
