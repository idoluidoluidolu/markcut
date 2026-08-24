import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/color_grade.dart';
import '../models/mosaic.dart';
import '../models/watermark_settings.dart';
import 'logo_mark_painter.dart';
import 'text_mark_painter.dart';

/// 把浮水印設定畫成點陣圖。
/// 預覽和輸出走同一套繪製邏輯，所以「看到的就是輸出的」。
/// 全部以 bytes 操作，手機與 Web 通用。
class WatermarkRenderer {
  /// 產生一張透明背景、大小等於輸出解析度的浮水印圖層 PNG，
  /// 之後交給 FFmpeg overlay 疊到影片上。
  static Future<Uint8List> renderOverlayPng(
    WatermarkSettings s,
    int outW,
    int outH,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    await drawMarks(canvas, s, outW.toDouble(), outH.toDouble());
    final picture = recorder.endRecording();
    final image = await picture.toImage(outW, outH);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// 照片浮水印：以原始解析度合成照片 + 馬賽克 + 浮水印，輸出 PNG（無損）。
  static Future<Uint8List> renderPhotoComposite(
    Uint8List photoBytes,
    WatermarkSettings s, {
    ColorGrade? grade,
    List<PhotoMosaic>? mosaics,
    List<WatermarkSettings>? extraMarks,
  }) async {
    final codec = await ui.instantiateImageCodec(photoBytes);
    final frame = await codec.getNextFrame();
    var photo = frame.image;
    final w = photo.width;
    final h = photo.height;

    // 有調色時先把「調完色的照片」烙成一張圖——
    // 馬賽克要取樣的是調色後的畫面（跟預覽/影片匯出一致）
    if (grade?.hasColor ?? false) {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawImage(
        photo,
        ui.Offset.zero,
        ui.Paint()..colorFilter = grade!.filter,
      );
      final graded = await rec.endRecording().toImage(w, h);
      photo.dispose();
      photo = graded;
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(photo, ui.Offset.zero, ui.Paint());
    // 馬賽克畫在浮水印下面（打碼的是照片，不是浮水印）
    for (final m in mosaics ?? const <PhotoMosaic>[]) {
      await _drawMosaic(canvas, photo, m, w, h);
    }
    await drawMarks(canvas, s, w.toDouble(), h.toDouble());
    // 更多浮水印：一組一組疊上去（照片模式可加好幾組）
    for (final e in extraMarks ?? const <WatermarkSettings>[]) {
      await drawMarks(canvas, e, w.toDouble(), h.toDouble());
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    photo.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// 在照片上畫一塊馬賽克（像素化＝縮小再鄰近放大、模糊、純色）。
  /// 格數/半徑公式跟影片匯出同一套，兩邊效果一致
  static Future<void> _drawMosaic(
    ui.Canvas canvas,
    ui.Image photo,
    PhotoMosaic m,
    int w,
    int h,
  ) async {
    final side = m.scale * math.min(w, h);
    var rect = ui.Rect.fromCenter(
      center: ui.Offset(m.x * w, m.y * h),
      width: side,
      height: side,
    ).intersect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    if (rect.width < 2 || rect.height < 2) return;

    final st = m.style;
    if (st.type == 2) {
      canvas.drawRect(rect, ui.Paint()..color = ui.Color(st.color));
      return;
    }
    if (st.type == 1) {
      // 模糊：半徑跟影片匯出同公式，按輸出解析度等比放大
      final sigma = math.max(
        2.0,
        (2 + st.strength * 18) * math.min(w, h) / 540,
      );
      final featherPx = st.feather * 0.2 * math.min(rect.width, rect.height);
      if (featherPx >= 1) {
        // 真羽化：模糊補丁先畫進一層，再用「內縮＋霧化」的白色方塊
        // 當 alpha 遮罩（dstIn），邊緣平滑淡出
        canvas.saveLayer(rect, ui.Paint());
        canvas.save();
        canvas.clipRect(rect);
        canvas.saveLayer(
          rect,
          ui.Paint()
            ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        );
        canvas.drawImage(photo, ui.Offset.zero, ui.Paint());
        canvas.restore();
        canvas.restore();
        // 遮罩用「圖層模糊」而不是 MaskFilter——web 支援不完整會硬邊
        canvas.saveLayer(
          rect,
          ui.Paint()
            ..blendMode = ui.BlendMode.dstIn
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: featherPx * 0.5,
              sigmaY: featherPx * 0.5,
            ),
        );
        canvas.drawRect(
          rect.deflate(featherPx),
          ui.Paint()..color = const ui.Color(0xFFFFFFFF),
        );
        canvas.restore();
        canvas.restore();
        return;
      }
      canvas.save();
      canvas.clipRect(rect);
      canvas.saveLayer(
        rect,
        ui.Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      );
      canvas.drawImage(photo, ui.Offset.zero, ui.Paint());
      canvas.restore();
      canvas.restore();
      return;
    }
    // 像素化：區域縮到 N 格再用「不插值」放大回去
    final cells = (26 - 20 * st.strength).round().clamp(4, 40);
    final sw = math.max(2, math.min(cells, rect.width ~/ 2));
    final sh = math.max(2, (sw * rect.height / rect.width).round());
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawImageRect(
      photo,
      rect,
      ui.Rect.fromLTWH(0, 0, sw.toDouble(), sh.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final small = await rec.endRecording().toImage(sw, sh);
    canvas.drawImageRect(
      small,
      ui.Rect.fromLTWH(0, 0, sw.toDouble(), sh.toDouble()),
      rect,
      ui.Paint()..filterQuality = ui.FilterQuality.none,
    );
    small.dispose();
  }

  /// 文字素材：以完整樣式＋位置＋縮放渲染成整版透明 PNG（匯出 overlay 用）
  static Future<Uint8List> renderTextClipPng(
    TextMark style,
    double px,
    double py,
    double scale,
    int outW,
    int outH,
  ) async {
    final t = style.copy()
      ..enabled = true
      ..x = px
      ..y = py
      ..sizeFrac = style.sizeFrac * scale;
    final s = WatermarkSettings(text: t, logo: LogoMark(enabled: false));
    return renderOverlayPng(s, outW, outH);
  }

  /// 在指定大小的畫布上畫出文字與 Logo 浮水印
  static Future<void> drawMarks(
    ui.Canvas canvas,
    WatermarkSettings s,
    double w,
    double h,
  ) async {
    // 圖片先畫（讓文字可以壓在圖片上面）。多張時照清單順序，
    // 後加的那張蓋在前面的上面——跟預覽的疊法一致
    for (final logo in s.logos) {
      final logoBytes = logo.bytes;
      if (!logo.enabled || logoBytes == null) continue;
      final codec = await ui.instantiateImageCodec(logoBytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;

      // 縮放/圓角/透明度/平鋪全交給共用畫家（跟預覽同一段程式碼）
      if (logo.tiled) {
        paintLogoTiled(canvas, logo, img, w, h);
        img.dispose();
        continue; // 平鋪的這張畫完，換下一張
      }

      // 不夾限：跟預覽同一套——拖出畫面的部分就讓它被畫布切掉
      final targetW = logo.sizeFrac * math.min(w, h); // 短邊基準
      final targetH = targetW * img.height / img.width;
      final left = logo.x * w - targetW / 2;
      final top = logo.y * h - targetH / 2;
      final rect = ui.Rect.fromLTWH(left, top, targetW, targetH);
      canvas.save();
      // 旋轉：以圖片中心為軸（預覽是 Transform.rotate 同軸心）
      if (logo.rotation.abs() > 0.01) {
        final c = rect.center;
        canvas.translate(c.dx, c.dy);
        canvas.rotate(logo.rotation * math.pi / 180);
        canvas.translate(-c.dx, -c.dy);
      }
      paintLogoUnit(canvas, logo, img, rect);
      canvas.restore();
      img.dispose();
    }

    _drawText(canvas, s, w, h);
  }

  /// 文字浮水印（含平鋪、底色、描邊、旋轉）。
  /// 文字可以有很多個，照清單順序畫（後加的在上）
  /// 把每一顆文字浮水印畫上畫布。
  ///
  /// 字形（陰影/描邊/本體）一律交給 [paintMarkGlyphs]——那是預覽
  /// 與匯出共用的「唯一畫法」，同一段程式碼跑兩次，輸出跟預覽
  /// 在數學上是同一件事。這裡只管：位置、旋轉、底色、滿版平鋪
  static void _drawText(
    ui.Canvas canvas,
    WatermarkSettings s,
    double w,
    double h,
  ) {
    for (final t in s.texts) {
      if (!t.enabled || t.text.trim().isEmpty) continue;
      // 不自動換行、也不自動縮小：使用者調多大就多大，
      // 超出畫面是允許的
      final fontSize = t.sizeFrac * math.min(w, h); // 短邊基準（跟預覽一致）
      final m = measureMark(t, fontSize);
      final padH = fontSize * 0.35 * t.bgPad;
      final padV = fontSize * 0.18 * t.bgPad;

      void bgRect(double x, double y) {
        if (!t.bg) return;
        canvas.drawRRect(
          ui.RRect.fromRectAndRadius(
            ui.Rect.fromLTWH(
              x - padH,
              y - padV,
              m.width + padH * 2,
              m.height + padV * 2,
            ),
            ui.Radius.circular(fontSize * t.bgCorner),
          ),
          ui.Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity),
        );
      }

      // 滿版平鋪（棋盤格）：整個畫面交錯重複，忽略 x/y
      if (t.tiled) {
        final stepX = m.width + fontSize * 2.2;
        final stepY = m.height + fontSize * 2.6;
        canvas.save();
        if (t.rotation.abs() > 0.01) {
          canvas.translate(w / 2, h / 2);
          canvas.rotate(t.rotation * math.pi / 180);
          canvas.translate(-w / 2, -h / 2);
        }
        var row = 0;
        for (var y = -h; y < h * 2; y += stepY, row++) {
          final shift = row.isOdd ? stepX / 2 : 0.0;
          for (var x = -w - shift; x < w * 2; x += stepX) {
            bgRect(x, y);
            paintMarkGlyphs(canvas, t, fontSize, ui.Offset(x, y));
          }
        }
        canvas.restore();
        continue;
      }

      // 單顆：中心點定位（不夾限，可拖出畫面）＋以中心為軸旋轉
      final left = t.x * w - m.width / 2;
      final top = t.y * h - m.height / 2;
      canvas.save();
      if (t.rotation.abs() > 0.01) {
        final cx = left + m.width / 2;
        final cy = top + m.height / 2;
        canvas.translate(cx, cy);
        canvas.rotate(t.rotation * math.pi / 180);
        canvas.translate(-cx, -cy);
      }
      bgRect(left, top);
      paintMarkGlyphs(canvas, t, fontSize, ui.Offset(left, top));
      canvas.restore();
    }
  }
}
