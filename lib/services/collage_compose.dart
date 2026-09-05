import 'dart:math' as math;
import 'dart:ui' as ui;

import '../models/watermark_settings.dart';
import 'watermark_renderer.dart';

/// 拼圖的取景數學與合成。預覽（collage_screen）跟匯出走同一段程式碼，
/// 所見即所得；這裡沒有任何 widget，測試可以直接以小尺寸合成驗像素。
///
/// 底是「透明」：空格子、自由模式沒被照片蓋到的地方什麼都不畫，
/// 之後存 PNG 一路保留（朋友回報過透明的組圖被強制上白底——不要再烙）

/// 每格的取景：cover 基準的縮放倍率（≥1）＋來源像素平移
class CollageCellFit {
  double zoom = 1;
  double panX = 0;
  double panY = 0;
}

/// 自由模式的一塊照片：哪張圖＋在畫布上的位置（0~1 比例座標，
/// 可以稍微出畫布——出血構圖）
class CollageFreeItem {
  final int img;
  ui.Rect rect;

  CollageFreeItem({required this.img, required this.rect});
}

/// 這一格目前的取景窗（來源圖片座標）。cover 基準：
/// zoom=1 剛好蓋滿格子，只能再放大；平移夾在圖片範圍內。
/// 預覽跟合成都用這個算，所見即所得
(double, double) collageSrcSize(
  ui.Image img,
  CollageCellFit f,
  double cellAspect,
) {
  final iw = img.width.toDouble();
  final ih = img.height.toDouble();
  double sw, sh;
  if (iw / ih > cellAspect) {
    sh = ih / f.zoom;
    sw = sh * cellAspect;
  } else {
    sw = iw / f.zoom;
    sh = sw / cellAspect;
  }
  return (math.min(sw, iw), math.min(sh, ih));
}

/// 把平移夾回「圖片還蓋得滿格子」的範圍。
/// 只在 [collageSrcRect] 裡夾的話，pan 本身會無上限累積
void collageClampFit(ui.Image img, CollageCellFit f, double cellAspect) {
  final (sw, sh) = collageSrcSize(img, f, cellAspect);
  final mx = (img.width - sw) / 2;
  final my = (img.height - sh) / 2;
  f.panX = f.panX.clamp(-mx, math.max(0.0, mx));
  f.panY = f.panY.clamp(-my, math.max(0.0, my));
}

ui.Rect collageSrcRect(ui.Image img, CollageCellFit f, double cellAspect) {
  final iw = img.width.toDouble();
  final ih = img.height.toDouble();
  // collageSrcSize 已經把取景窗夾在圖片內（web 的繪圖引擎對出界很嚴格）
  final (sw, sh) = collageSrcSize(img, f, cellAspect);
  // clamp 的上限不能是負的（浮點誤差會讓 iw-sw 變 -0.0001 直接炸）
  final mx = (iw - sw) > 0 ? iw - sw : 0.0;
  final my = (ih - sh) > 0 ? ih - sh : 0.0;
  var cx = (iw - sw) / 2 + f.panX;
  var cy = (ih - sh) / 2 + f.panY;
  cx = cx.clamp(0.0, mx);
  cy = cy.clamp(0.0, my);
  return ui.Rect.fromLTWH(cx, cy, sw, sh);
}

/// 照片塞進某個長寬比的框時的取景窗（置中 cover，不變形）
ui.Rect collageCoverSrc(ui.Image img, double aspect) {
  final iw = img.width.toDouble();
  final ih = img.height.toDouble();
  double sw, sh;
  if (iw / ih > aspect) {
    sh = ih;
    sw = sh * aspect;
  } else {
    sw = iw;
    sh = sw / aspect;
  }
  return ui.Rect.fromLTWH((iw - sw) / 2, (ih - sh) / 2, sw, sh);
}

/// 拼圖的排法：合成時拍的一份快照（清單直接引用畫面上的那幾份，
/// 不複製——合成把繪圖指令錄進 PictureRecorder 是同步的，錄完才 await）
class CollageLayout {
  /// 自由模式（true）還是宮格（false）
  final bool free;

  /// 宮格的欄與列
  final int cols;
  final int rows;

  /// 每個格子放哪張照片（[images] 的索引；-1＝空格，合成時留透明）
  final List<int> order;

  /// 每格的取景（跟 [order] 同索引）
  final List<CollageCellFit> fits;

  /// 自由模式的方塊（畫的順序＝疊的順序）
  final List<CollageFreeItem> items;

  /// 畫布比例（寬/高）
  final double canvasAspect;

  /// 格線（宮格才有）：開關、線寬（畫布寬的比例）、顏色（ARGB）
  final bool lines;
  final double gapN;
  final int lineColor;

  const CollageLayout({
    required this.free,
    required this.cols,
    required this.rows,
    required this.order,
    required this.fits,
    required this.items,
    required this.canvasAspect,
    this.lines = false,
    this.gapN = 0.008,
    this.lineColor = 0xFFFFFFFF,
  });

  int get cellCount => cols * rows;
}

/// 輸出畫布的長邊（像素）。自由排版固定 2048；宮格跟著格數長——
/// 格子多的時候固定 1600 會讓每格只剩百來 px，上限 2400（再大 PNG
/// 編碼在 web 會卡住主執行緒）
double collageLongSide(CollageLayout l) {
  if (l.free) return 2048;
  return (math.max(l.cols, l.rows) * 420.0).clamp(1600.0, 2400.0);
}

/// 畫布的寬高（像素）：長邊照 [longSide]，另一邊照畫布比例
(int, int) collageCanvasSize(CollageLayout l, double longSide) {
  final a = l.canvasAspect;
  final w = a >= 1 ? longSide : longSide * a;
  final h = a >= 1 ? longSide / a : longSide;
  return (math.max(1, w.round()), math.max(1, h.round()));
}

/// 把拼圖畫在 [canvas] 上（[w]×[h] 像素，透明底，不畫背景）。
/// 宮格：照片貼齊排滿、格線最後疊上去；自由：照疊放順序畫，
/// 方塊拉出畫布的部分自然被裁掉（跟預覽看到的一樣）
void drawCollage(
  ui.Canvas canvas,
  CollageLayout l,
  List<ui.Image?> images,
  double w,
  double h,
) {
  ui.Image? imgAt(int idx) =>
      (idx >= 0 && idx < images.length) ? images[idx] : null;
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
  if (l.free) {
    for (final it in l.items) {
      final img = imgAt(it.img);
      if (img == null) continue;
      final dst = ui.Rect.fromLTWH(
        it.rect.left * w,
        it.rect.top * h,
        it.rect.width * w,
        it.rect.height * h,
      );
      canvas.drawImageRect(
        img,
        collageCoverSrc(img, dst.width / dst.height),
        dst,
        paint,
      );
    }
    return;
  }
  final cw = w / l.cols;
  final ch = h / l.rows;
  for (var i = 0; i < l.cellCount; i++) {
    final img = i < l.order.length ? imgAt(l.order[i]) : null;
    if (img == null) continue; // 空格＝透明
    final fit = i < l.fits.length ? l.fits[i] : CollageCellFit();
    final dst = ui.Rect.fromLTWH((i % l.cols) * cw, (i ~/ l.cols) * ch, cw, ch);
    canvas.drawImageRect(img, collageSrcRect(img, fit, cw / ch), dst, paint);
  }
  if (l.lines) {
    final t = l.gapN * w;
    final lp = ui.Paint()..color = ui.Color(l.lineColor);
    for (var c = 1; c < l.cols; c++) {
      canvas.drawRect(ui.Rect.fromLTWH(c * cw - t / 2, 0, t, h), lp);
    }
    for (var r = 1; r < l.rows; r++) {
      canvas.drawRect(ui.Rect.fromLTWH(0, r * ch - t / 2, w, t), lp);
    }
  }
}

/// 合成一張：拼圖＋浮水印一次畫完（浮水印走匯出共用的
/// [WatermarkRenderer.drawMarks]，跟預覽圖層同一段畫法）。
/// [longSide] 不給就是 [collageLongSide]；測試給小一點驗像素。
/// 回傳的圖要自己 dispose；傳進來的照片不碰
/// [background]：先鋪一層底色再畫。JPEG 沒有透明，空格子總得是個顏色
///（定黑）；PNG 不給＝空格留透明
Future<ui.Image> composeCollage(
  CollageLayout l,
  List<ui.Image?> images, {
  WatermarkSettings? watermark,
  double? longSide,
  ui.Color? background,
}) async {
  final (w, h) = collageCanvasSize(l, longSide ?? collageLongSide(l));
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  if (background != null) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = background,
    );
  }
  drawCollage(canvas, l, images, w.toDouble(), h.toDouble());
  if (watermark != null) {
    await WatermarkRenderer.drawMarks(
      canvas,
      watermark,
      w.toDouble(),
      h.toDouble(),
    );
  }
  final picture = rec.endRecording();
  final image = await picture.toImage(w, h);
  picture.dispose();
  return image;
}
