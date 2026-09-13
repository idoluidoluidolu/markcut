import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart';

import '../models/watermark_settings.dart';
import 'quality_diagnostics.dart';

// ===== 解碼好的 Logo 共用池 =====
//
// 鍵是 bytes 物件本身：同一顆 Logo 的 base64 有池子（LogoMark.bytes），
// 所有副本拿到同一個 bytes 物件，Expando 跟著物件活、物件回收快取自然消。
// 以前預覽圖層量長寬比整張解一次、_LogoUnit 畫再解一次、平鋪層再一次、
// 匯出再一次——4MB 的大圖每個地方各來一輪（主層、每組額外層、全螢幕層、
// 範本卡）。同一尺寸只解一次；預覽限長邊、匯出保留原圖。解好的圖
// 不 dispose（跟著 bytes
// 活，bytes 被回收時由引擎的終結器收）
const kLogoPreviewMaxSide = 1080;
final Expando<Map<int, ui.Image>> _logoImages = Expando('logoImages');
final Expando<Map<int, Future<ui.Image>>> _logoDecoding = Expando(
  'logoDecoding',
);

/// 已經解好的 Logo（還沒解好回 null，用 [logoImageFor] 去等）
ui.Image? logoImageCached(Uint8List bytes, {int? maxSide}) =>
    _logoImages[bytes]?[maxSide ?? 0];

/// 解碼一顆 Logo（同一份 bytes 只解一次；正在解的一起等同一個 Future）
Future<ui.Image> logoImageFor(Uint8List bytes, {int? maxSide}) {
  final key = maxSide ?? 0;
  final hit = _logoImages[bytes]?[key];
  if (hit != null) return Future.value(hit);
  final pending = _logoDecoding[bytes] ??= {};
  final inflight = pending[key];
  if (inflight != null) return inflight;
  final f = _decodeLogo(bytes, maxSide);
  pending[key] = f;
  return f;
}

Future<ui.Image> _decodeLogo(Uint8List bytes, int? maxSide) async {
  final diagnostic = QualityDiagnostics.instance;
  final span = maxSide == null
      ? null
      : diagnostic.begin(QualityMetric.logoDecode);
  var succeeded = false;
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    ui.Image img;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      final downsample = maxSide != null && math.max(w, h) > maxSide;
      codec = await descriptor.instantiateCodec(
        targetWidth: downsample && w >= h ? maxSide : null,
        targetHeight: downsample && h > w ? maxSide : null,
      );
      img = (await codec.getNextFrame()).image;
    } on UnsupportedError {
      // Older web renderers do not expose ImageDescriptor. Keep the established
      // codec path there, limiting the second decode to preview size if needed.
      codec?.dispose();
      codec = null;
      codec = await ui.instantiateImageCodec(bytes);
      img = (await codec.getNextFrame()).image;
      final w = img.width, h = img.height;
      if (maxSide != null && math.max(w, h) > maxSide) {
        img.dispose();
        codec.dispose();
        codec = null;
        codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: w >= h ? maxSide : null,
          targetHeight: h > w ? maxSide : null,
        );
        img = (await codec.getNextFrame()).image;
      }
    }
    (_logoImages[bytes] ??= {})[maxSide ?? 0] = img;
    succeeded = true;
    return img;
  } finally {
    diagnostic.finish(span, success: succeeded);
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
    _logoDecoding[bytes]?.remove(maxSide ?? 0);
  }
}

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
