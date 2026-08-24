import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';

import '../models/watermark_settings.dart';

/// 圖片 Logo 浮水印的「唯一畫法」（跟文字的 text_mark_painter 同一個
/// 思路）：預覽（WatermarkLayer）與匯出（WatermarkRenderer）都直接
/// 執行這裡的函式——同一段程式碼跑兩次，成品跟預覽在數學上是同一
/// 件事，改常數只有一個地方可改，不可能兩邊走鐘。
///
/// 旋轉不在這裡：單顆的旋轉由呼叫端以「中心為軸」自己轉
///（預覽是 Transform.rotate 帶著選取框一起轉，匯出是 canvas
/// translate/rotate，數學相同）；平鋪的旋轉是整面轉，包含在
/// [paintLogoTiled] 內。

/// 單顆 Logo 畫進 [rect]：圓角裁切＋透明度＋高品質取樣
void paintLogoUnit(
  ui.Canvas canvas,
  LogoMark logo,
  ui.Image img,
  ui.Rect rect,
) {
  final src = ui.Rect.fromLTWH(
    0,
    0,
    img.width.toDouble(),
    img.height.toDouble(),
  );
  final paint = ui.Paint()
    ..filterQuality = ui.FilterQuality.high
    ..color = const ui.Color(0xFFFFFFFF).withValues(alpha: logo.opacity);
  if (logo.corner > 0.01) {
    // 圓角基準：短邊（corner=1 時短邊剛好整個圓）
    final r = logo.corner * math.min(rect.width, rect.height) / 2;
    canvas.save();
    canvas.clipRRect(ui.RRect.fromRectAndRadius(rect, ui.Radius.circular(r)));
    canvas.drawImageRect(img, src, rect, paint);
    canvas.restore();
  } else {
    canvas.drawImageRect(img, src, rect, paint);
  }
}

/// 滿版平鋪（棋盤格）：整面交錯重複，忽略 x/y。
/// 大小以短邊為基準；奇數列半格錯開；整面以畫布中心旋轉
void paintLogoTiled(
  ui.Canvas canvas,
  LogoMark logo,
  ui.Image img,
  double w,
  double h,
) {
  final targetW = logo.sizeFrac * math.min(w, h);
  final targetH = targetW * img.height / img.width;
  final stepX = targetW * 1.8;
  final stepY = targetH * 1.9;
  canvas.save();
  canvas.clipRect(ui.Rect.fromLTWH(0, 0, w, h));
  if (logo.rotation.abs() > 0.01) {
    canvas.translate(w / 2, h / 2);
    canvas.rotate(logo.rotation * math.pi / 180);
    canvas.translate(-w / 2, -h / 2);
  }
  var row = 0;
  for (var y = -h; y < h * 2; y += stepY, row++) {
    final shift = row.isOdd ? stepX / 2 : 0.0;
    for (var x = -w - shift; x < w * 2; x += stepX) {
      paintLogoUnit(
        canvas,
        logo,
        img,
        ui.Rect.fromLTWH(x, y, targetW, targetH),
      );
    }
  }
  canvas.restore();
}

/// 給 widget 用：在自己的版面大小裡畫一顆 Logo（單顆；旋轉在外層）。
/// img 還沒解碼好時什麼都不畫（跟 Image.memory 首幀空白一樣）
class LogoUnitPainter extends CustomPainter {
  final LogoMark logo;
  final ui.Image? img;

  /// 內容值快照（LogoMark 是就地修改的，比 reference 沒有意義）
  final List<Object?> _sig;

  LogoUnitPainter(this.logo, this.img)
    : _sig = [img, logo.opacity, logo.corner];

  @override
  void paint(ui.Canvas canvas, Size size) {
    final im = img;
    if (im == null) return;
    paintLogoUnit(canvas, logo, im, ui.Offset.zero & size);
  }

  @override
  bool shouldRepaint(covariant LogoUnitPainter old) =>
      !listEquals(old._sig, _sig);
}
