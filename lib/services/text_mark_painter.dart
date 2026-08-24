import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../models/watermark_settings.dart';

/// 文字浮水印的「唯一畫法」。
///
/// 預覽（WatermarkLayer 的 CustomPaint）與匯出（WatermarkRenderer）
/// 都直接執行這一個函式——同一段程式碼跑兩次，輸出跟預覽在數學上
/// 是同一件事，不存在「對不齊」。
///
/// 鐵律：文字本身只用「填色文字／描邊文字」兩種原語。
/// - 不用 TextStyle.shadows / MaskFilter：這種「字型層」濾鏡在
///   Impeller 的離屏 toImage 會被丟掉（預覽有、成品沒有的慘案）
/// - 不用離屏影像縮放模擬模糊：放大取樣會走樣，還踩過「餘數沒乘、
///   陰影縮小錯位」的坑
/// - 同步、無狀態：預覽每一格直接重畫，滑桿即時跟手
///
/// 陰影＝把「填色黑字」畫進一層 saveLayer，用合成層級的
/// ImageFilter.blur 做真高斯——這是畫布合成功能（BackdropFilter
/// 同一套管線），不是字型濾鏡，離屏 toImage 照樣生效。
/// 之前試過的描邊光暈近似在大字會現出一圈圈「空心管」，棄用。
/// shadowBlur=0 時直接畫，就是俐落的硬影。
void paintMarkGlyphs(
  ui.Canvas canvas,
  TextMark t,
  double fontSize,
  ui.Offset at,
) {
  TextPainter layout(TextStyle style) => TextPainter(
    text: TextSpan(text: t.text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();

  final base = TextStyle(
    fontFamily: t.fontFamily,
    fontSize: fontSize,
    letterSpacing: fontSize * t.spacing,
  );

  // ── 陰影（saveLayer＋真高斯）──
  if (t.shadow && t.shadowOpacity > 0.01) {
    final off = ui.Offset(at.dx + fontSize * 0.03, at.dy + fontSize * 0.03);
    final sigma = fontSize * t.shadowBlur;
    final a = (t.shadowOpacity * t.opacity).clamp(0.0, 1.0);
    final sp = layout(
      base.copyWith(color: const ui.Color(0xFF000000).withValues(alpha: a)),
    );
    if (sigma > 0.3) {
      // 圖層邊界收在文字附近：模糊尾巴 3σ 之外就看不見了，
      // 不用整張畫布都進離屏層
      final bounds = ui.Rect.fromLTWH(
        off.dx,
        off.dy,
        sp.width,
        sp.height,
      ).inflate(sigma * 3 + 1);
      canvas.saveLayer(
        bounds,
        ui.Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: ui.TileMode.decal,
          ),
      );
      sp.paint(canvas, off);
      canvas.restore();
    } else {
      sp.paint(canvas, off);
    }
  }

  // ── 描邊 ──
  if (t.outline) {
    layout(
      base.copyWith(
        foreground: ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = (fontSize * t.outlineWidth).clamp(1.0, 4096.0)
          ..strokeJoin = ui.StrokeJoin.round
          ..color = Color(t.outlineColorValue).withValues(alpha: t.opacity),
      ),
    ).paint(canvas, at);
  }

  // ── 本體 ──
  layout(
    base.copyWith(color: Color(t.colorValue).withValues(alpha: t.opacity)),
  ).paint(canvas, at);
}

/// 量文字的版面大小（跟 [paintMarkGlyphs] 同一套字型參數）
Size measureMark(TextMark t, double fontSize) {
  final p = TextPainter(
    text: TextSpan(
      text: t.text,
      style: TextStyle(
        fontFamily: t.fontFamily,
        fontSize: fontSize,
        letterSpacing: fontSize * t.spacing,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  return Size(p.width, p.height);
}

/// 給 widget 用的畫家：在自己的座標原點畫一顆文字浮水印。
/// 陰影會凸出版面（CustomPaint 預設不裁切，凸出照畫）
class MarkGlyphPainter extends CustomPainter {
  final TextMark t;
  final double fontSize;

  /// 內容值的快照（TextMark 是就地修改的，比 reference 沒有意義）
  final List<Object?> _sig;

  MarkGlyphPainter(this.t, this.fontSize)
    : _sig = [
        t.text,
        t.fontFamily,
        fontSize,
        t.spacing,
        t.colorValue,
        t.opacity,
        t.shadow,
        t.shadowOpacity,
        t.shadowBlur,
        t.outline,
        t.outlineColorValue,
        t.outlineWidth,
      ];

  @override
  void paint(ui.Canvas canvas, Size size) {
    paintMarkGlyphs(canvas, t, fontSize, ui.Offset.zero);
  }

  @override
  bool shouldRepaint(covariant MarkGlyphPainter old) {
    if (old._sig.length != _sig.length) return true;
    for (var i = 0; i < _sig.length; i++) {
      if (old._sig[i] != _sig[i]) return true;
    }
    return false;
  }
}
