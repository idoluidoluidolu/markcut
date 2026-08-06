import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../models/watermark_settings.dart';

/// 把浮水印設定畫成點陣圖。
/// 預覽和輸出走同一套繪製邏輯，所以「看到的就是輸出的」。
/// 全部以 bytes 操作，手機與 Web 通用。
class WatermarkRenderer {
  /// 產生一張透明背景、大小等於輸出解析度的浮水印圖層 PNG，
  /// 之後交給 FFmpeg overlay 疊到影片上。
  static Future<Uint8List> renderOverlayPng(
      WatermarkSettings s, int outW, int outH) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    await drawMarks(canvas, s, outW.toDouble(), outH.toDouble());
    final picture = recorder.endRecording();
    final image = await picture.toImage(outW, outH);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// 照片浮水印：以原始解析度合成照片 + 浮水印，輸出 PNG（無損）。
  static Future<Uint8List> renderPhotoComposite(
      Uint8List photoBytes, WatermarkSettings s) async {
    final codec = await ui.instantiateImageCodec(photoBytes);
    final frame = await codec.getNextFrame();
    final photo = frame.image;
    final w = photo.width;
    final h = photo.height;

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(photo, ui.Offset.zero, ui.Paint());
    await drawMarks(canvas, s, w.toDouble(), h.toDouble());
    final picture = recorder.endRecording();
    final image = await picture.toImage(w, h);
    photo.dispose();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  /// 文字素材：以完整樣式＋位置＋縮放渲染成整版透明 PNG（匯出 overlay 用）
  static Future<Uint8List> renderTextClipPng(TextMark style, double px,
      double py, double scale, int outW, int outH) async {
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
      ui.Canvas canvas, WatermarkSettings s, double w, double h) async {
    // Logo 先畫（讓文字可以壓在 Logo 上面）
    final logo = s.logo;
    final logoBytes = logo.bytes;
    if (logo.enabled && logoBytes != null) {
      final codec = await ui.instantiateImageCodec(logoBytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;

      final targetW = logo.sizeFrac * w;
      final targetH = targetW * img.height / img.width;
      final srcRect = ui.Rect.fromLTWH(
          0, 0, img.width.toDouble(), img.height.toDouble());

      // Logo 滿版平鋪（棋盤格）：整面交錯重複，忽略 x/y
      if (logo.tiled) {
        final stepX = targetW * 1.8;
        final stepY = targetH * 1.9;
        final tilePaint = ui.Paint()
          ..filterQuality = ui.FilterQuality.high
          ..color =
              const ui.Color(0xFFFFFFFF).withValues(alpha: logo.opacity);
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
              canvas.clipRRect(ui.RRect.fromRectAndRadius(
                  rect, ui.Radius.circular(r)));
              canvas.drawImageRect(img, srcRect, rect, tilePaint);
              canvas.restore();
            } else {
              canvas.drawImageRect(img, srcRect, rect, tilePaint);
            }
          }
        }
        canvas.restore();
        img.dispose();
        // 平鋪畫完直接跳去畫文字
        _drawText(canvas, s, w, h);
        return;
      }

      // 夾在畫面內，太靠邊不會被裁掉
      final pad = w * 0.012;
      final left = (logo.x * w - targetW / 2)
          .clamp(pad, math.max(pad, w - targetW - pad))
          .toDouble();
      final top = (logo.y * h - targetH / 2)
          .clamp(pad, math.max(pad, h - targetH - pad))
          .toDouble();
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
            ui.RRect.fromRectAndRadius(rect, ui.Radius.circular(r)));
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

    _drawText(canvas, s, w, h);
  }

  /// 文字浮水印（含平鋪、底色、描邊、旋轉）
  static void _drawText(
      ui.Canvas canvas, WatermarkSettings s, double w, double h) {
    final t = s.text;
    if (t.enabled && t.text.trim().isNotEmpty) {
      // 不自動換行：過寬時整段等比縮小字級（明確換行 \n 仍有效）
      var fontSize = t.sizeFrac * w;
      final maxW = w * 0.96;

      TextPainter measure(double fs) => TextPainter(
            text: TextSpan(
              text: t.text,
              style: TextStyle(
                  fontFamily: t.fontFamily,
                  fontSize: fs,
                  letterSpacing: fs * t.spacing),
            ),
            textDirection: TextDirection.ltr,
          )..layout();

      var probe = measure(fontSize);
      if (probe.width > maxW) {
        fontSize *= maxW / probe.width;
        probe = measure(fontSize);
      }

      final shadows = t.shadow
          ? [
              Shadow(
                color: const ui.Color(0xFF000000)
                    .withValues(alpha: 0.55 * t.opacity),
                blurRadius: fontSize * 0.08,
                offset: ui.Offset(fontSize * 0.03, fontSize * 0.03),
              ),
            ]
          : null;
      final painter = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            fontFamily: t.fontFamily,
            fontSize: fontSize,
            letterSpacing: fontSize * t.spacing,
            color: t.color.withValues(alpha: t.opacity),
            shadows: shadows,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
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
                  ui.Rect.fromLTWH(x - padH, y - padV,
                      painter.width + padH * 2, painter.height + padV * 2),
                  ui.Radius.circular(fontSize * t.bgCorner),
                ),
                ui.Paint()
                  ..color = t.bgColor.withValues(alpha: t.bgOpacity),
              );
            }
            strokePainter?.paint(canvas, ui.Offset(x, y));
            painter.paint(canvas, ui.Offset(x, y));
          }
        }
        canvas.restore();
        return;
      }

      // 夾在畫面內，靠邊也不會被裁
      final pad = w * 0.012;
      final left = (t.x * w - painter.width / 2)
          .clamp(pad, math.max(pad, w - painter.width - pad))
          .toDouble();
      final top = (t.y * h - painter.height / 2)
          .clamp(pad, math.max(pad, h - painter.height - pad))
          .toDouble();

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
            ui.Rect.fromLTWH(left - padH, top - padV,
                painter.width + padH * 2, painter.height + padV * 2),
            ui.Radius.circular(fontSize * t.bgCorner),
          ),
          ui.Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity),
        );
      }
      // 描邊（自訂顏色與粗度）
      strokePainter?.paint(canvas, ui.Offset(left, top));
      painter.paint(canvas, ui.Offset(left, top));
      canvas.restore();
    }
  }
}
