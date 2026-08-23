import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../models/color_grade.dart';
import '../models/mosaic.dart';
import '../models/watermark_settings.dart';

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

      final targetW = logo.sizeFrac * math.min(w, h); // 短邊基準（跟預覽一致）
      final targetH = targetW * img.height / img.width;
      final srcRect = ui.Rect.fromLTWH(
        0,
        0,
        img.width.toDouble(),
        img.height.toDouble(),
      );

      // Logo 滿版平鋪（棋盤格）：整面交錯重複，忽略 x/y
      if (logo.tiled) {
        final stepX = targetW * 1.8;
        final stepY = targetH * 1.9;
        final tilePaint = ui.Paint()
          ..filterQuality = ui.FilterQuality.high
          ..color = const ui.Color(0xFFFFFFFF).withValues(alpha: logo.opacity);
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
            final rect = ui.Rect.fromLTWH(x, y, targetW, targetH);
            if (logo.corner > 0.01) {
              final r = logo.corner * math.min(targetW, targetH) / 2;
              canvas.save();
              canvas.clipRRect(
                ui.RRect.fromRectAndRadius(rect, ui.Radius.circular(r)),
              );
              canvas.drawImageRect(img, srcRect, rect, tilePaint);
              canvas.restore();
            } else {
              canvas.drawImageRect(img, srcRect, rect, tilePaint);
            }
          }
        }
        canvas.restore();
        img.dispose();
        continue; // 平鋪的這張畫完，換下一張
      }

      // 不夾限：跟預覽同一套——拖出畫面的部分就讓它被畫布切掉
      final left = logo.x * w - targetW / 2;
      final top = logo.y * h - targetH / 2;
      final rect = ui.Rect.fromLTWH(left, top, targetW, targetH);
      final paint = ui.Paint()
        ..filterQuality = ui.FilterQuality.high
        ..color = const ui.Color(0xFFFFFFFF).withValues(alpha: logo.opacity);

      canvas.save();
      // 旋轉：以圖片中心為軸
      if (logo.rotation.abs() > 0.01) {
        final c = rect.center;
        canvas.translate(c.dx, c.dy);
        canvas.rotate(logo.rotation * math.pi / 180);
        canvas.translate(-c.dx, -c.dy);
      }
      // 圓角：先裁再畫
      if (logo.corner > 0.01) {
        final r = logo.corner * math.min(targetW, targetH) / 2;
        canvas.clipRRect(
          ui.RRect.fromRectAndRadius(rect, ui.Radius.circular(r)),
        );
      }
      canvas.drawImageRect(
        img,
        ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        rect,
        paint,
      );
      canvas.restore();
      img.dispose();
    }

    await _drawText(canvas, s, w, h);
  }

  /// 文字浮水印（含平鋪、底色、描邊、旋轉）。
  /// 文字可以有很多個，照清單順序畫（後加的在上）
  static Future<void> _drawText(
    ui.Canvas canvas,
    WatermarkSettings s,
    double w,
    double h,
  ) async {
    for (final t in s.texts) {
      if (t.enabled && t.text.trim().isNotEmpty) {
        // 不自動換行、也不自動縮小：使用者調多大就多大，
        // 超出畫面是允許的（明確換行 \n 仍有效）
        final fontSize = t.sizeFrac * math.min(w, h); // 短邊基準（跟預覽一致）

        // 陰影不走 TextStyle.shadows（Impeller 離屏 toImage 會丟），
        // 也不用五印近似（大字會露出離散鬼影，實測回報「樣式很怪」）。
        // 真柔影：黑字畫進縮小的離屏圖，再拉回原尺寸貼上——
        // 縮小→雙線性放大就是真實模糊，只用取樣、不用任何濾鏡，
        // 任何渲染後端都支援
        final painter = TextPainter(
          text: TextSpan(
            text: t.text,
            style: TextStyle(
              fontFamily: t.fontFamily,
              fontSize: fontSize,
              letterSpacing: fontSize * t.spacing,
              color: t.color.withValues(alpha: t.opacity),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // 柔影小圖：把黑字以 1/k 縮小畫進離屏圖（邊緣留 blur 的
        // 出血），貼回來時用取樣放大——等效半徑 ≈ k/2 像素
        ui.Image? shadowImg;
        var shadowMargin = 0.0;
        var shadowScale = 1.0;
        if (t.shadow) {
          final blur = fontSize * 0.08;
          shadowScale = (blur * 0.9).clamp(2.0, 64.0);
          shadowMargin = blur * 2;
          final rec = ui.PictureRecorder();
          final sc = ui.Canvas(rec);
          sc.scale(1 / shadowScale);
          final sp2 = TextPainter(
            text: TextSpan(
              text: t.text,
              style: TextStyle(
                fontFamily: t.fontFamily,
                fontSize: fontSize,
                letterSpacing: fontSize * t.spacing,
                color: const ui.Color(
                  0xFF000000,
                ).withValues(alpha: (0.55 * t.opacity).clamp(0.0, 1.0)),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          sp2.paint(sc, ui.Offset(shadowMargin, shadowMargin));
          final sw2 = ((sp2.width + shadowMargin * 2) / shadowScale)
              .ceil()
              .clamp(1, 4096);
          final sh2 = ((sp2.height + shadowMargin * 2) / shadowScale)
              .ceil()
              .clamp(1, 4096);
          shadowImg = await rec.endRecording().toImage(sw2, sh2);
        }

        void stampShadow(double x, double y) {
          final img = shadowImg;
          if (img == null) return;
          final ox = fontSize * 0.03;
          final oy = fontSize * 0.03;
          canvas.drawImageRect(
            img,
            ui.Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            ui.Rect.fromLTWH(
              x + ox - shadowMargin,
              y + oy - shadowMargin,
              img.width * shadowScale,
              img.height * shadowScale,
            ),
            ui.Paint()..filterQuality = ui.FilterQuality.medium,
          );
        }

        // 描邊畫筆（平鋪與單顆共用）
        TextPainter? strokePainter;
        if (t.outline) {
          strokePainter = TextPainter(
            text: TextSpan(
              text: t.text,
              style: TextStyle(
                fontFamily: t.fontFamily,
                fontSize: fontSize,
                letterSpacing: fontSize * t.spacing,
                foreground: ui.Paint()
                  ..style = ui.PaintingStyle.stroke
                  ..strokeWidth = math.max(1, fontSize * t.outlineWidth)
                  ..color = t.outlineColor.withValues(alpha: t.opacity),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
        }

        // 滿版平鋪（棋盤格）：整個畫面交錯重複，忽略 x/y
        if (t.tiled) {
          final stepX = painter.width + fontSize * 2.2;
          final stepY = painter.height + fontSize * 2.6;
          final padH = fontSize * 0.35 * t.bgPad;
          final padV = fontSize * 0.18 * t.bgPad;
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
              // 每一顆都畫完整的底色→描邊→文字
              if (t.bg) {
                canvas.drawRRect(
                  ui.RRect.fromRectAndRadius(
                    ui.Rect.fromLTWH(
                      x - padH,
                      y - padV,
                      painter.width + padH * 2,
                      painter.height + padV * 2,
                    ),
                    ui.Radius.circular(fontSize * t.bgCorner),
                  ),
                  ui.Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity),
                );
              }
              stampShadow(x, y);
              strokePainter?.paint(canvas, ui.Offset(x, y));
              painter.paint(canvas, ui.Offset(x, y));
            }
          }
          canvas.restore();
          shadowImg?.dispose();
          return;
        }

        // 不夾限（理由同 Logo）
        final left = t.x * w - painter.width / 2;
        final top = t.y * h - painter.height / 2;

        // 旋轉：整組（底色＋描邊＋文字）以文字中心為軸
        canvas.save();
        if (t.rotation.abs() > 0.01) {
          final cx = left + painter.width / 2;
          final cy = top + painter.height / 2;
          canvas.translate(cx, cy);
          canvas.rotate(t.rotation * math.pi / 180);
          canvas.translate(-cx, -cy);
        }
        // 底色塊（自訂顏色、透明度、留白倍率、圓角）
        if (t.bg) {
          final padH = fontSize * 0.35 * t.bgPad;
          final padV = fontSize * 0.18 * t.bgPad;
          canvas.drawRRect(
            ui.RRect.fromRectAndRadius(
              ui.Rect.fromLTWH(
                left - padH,
                top - padV,
                painter.width + padH * 2,
                painter.height + padV * 2,
              ),
              ui.Radius.circular(fontSize * t.bgCorner),
            ),
            ui.Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity),
          );
        }
        // 柔影 → 描邊 → 文字
        stampShadow(left, top);
        strokePainter?.paint(canvas, ui.Offset(left, top));
        painter.paint(canvas, ui.Offset(left, top));
        canvas.restore();
        shadowImg?.dispose();
      }
    }
  }
}
