import 'dart:math' as math;
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
/// - 所有尺寸一律是字級的倍數，不准出現絕對像素常數：540p 快烘、
///   1080p 全解析、螢幕預覽三邊只差重取樣，幾何完全一樣
///
/// 透明度模型（跟業界文字工具一樣：透明度作用在「整個文字物件」）：
/// 陰影、描邊、加粗、本體全部先以不透明畫進同一層 saveLayer，整層
/// 再按文字透明度合成一次。這樣：
/// - 半透明字的字肚裡不會透出自己的陰影（以前 70% 白字下面壓著
///   黑影，字肚變灰）
/// - 描邊跟本體交界不會 alpha 相乘變濃（以前描邊在層外、本體在
///   層內，字緣浮出一圈更深的框——「粗細調起來怪怪的」）
/// - 陰影的剪影＝描邊＋加粗後的整個字（以前只有字形本身，描邊
///   一開、3% 的影子整個被 3.5% 的描邊圈蓋掉＝陰影消失）
///
/// 陰影＝把剪影畫進一層 saveLayer，用合成層級的 ImageFilter.blur
/// 做真高斯——這是畫布合成功能（BackdropFilter 同一套管線），不是
/// 字型濾鏡，離屏 toImage 照樣生效。shadowBlur=0 就是俐落的硬影。
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

  ui.Paint strokePaint(double width, ui.Color color) => ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = ui.StrokeJoin.round
    ..strokeCap = ui.StrokeCap.round
    ..color = color;

  // 加粗量（描邊式）：字型多半只有一個字重，換 fontWeight 沒反應，
  // 用同色描邊把字撐粗才是每個字型都吃得到的做法。
  // 門檻比「滑桿值」不比像素：預覽縮圖跟成品才會在同一個設定值切換
  final hasBold = t.weight > 0.005;
  final boldPx = hasBold ? fontSize * 0.06 * t.weight : 0.0;
  // 描邊要包住加粗後的字，所以寬度含 boldPx（描邊線一半在字內、
  // 一半在字外，露在外面的圈＝fontSize×outlineWidth/2）
  final outlinePx = t.outline ? fontSize * t.outlineWidth + boldPx : 0.0;
  final hasShadow = t.shadow && t.shadowOpacity > 0.01;
  final shadowOff = fontSize * 0.03;
  final sigma = hasShadow ? fontSize * t.shadowBlur : 0.0;
  final blurred = hasShadow && t.shadowBlur > 0.001;
  // 剪影往字外長的量（描邊／加粗各有一半在字外）
  final spread = math.max(outlinePx, boldPx) / 2;
  // 墨水常凸出行高（圓體筆頭、花體字尾），離屏層邊界要留餘裕：
  // Impeller 會把內容裁到 saveLayer 邊界，以前只留 boldPx+2px，
  // 開加粗就把凸出的筆畫削掉
  final inkSlack = fontSize * 0.3;

  final bodyOpaque = Color(t.colorValue);
  final fill = layout(base.copyWith(color: bodyOpaque));
  final inkBox = ui.Rect.fromLTWH(at.dx, at.dy, fill.width, fill.height);

  // ── 整組一層 ──（不透明時不用開層：不透明的本體本來就蓋住底下）
  final opacity = t.opacity.clamp(0.0, 1.0);
  final grouped = opacity < 0.999;
  if (grouped) {
    final reach = inkSlack + spread + (hasShadow ? shadowOff + sigma * 3 : 0.0);
    canvas.saveLayer(
      inkBox.inflate(reach),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF).withValues(alpha: opacity),
    );
  }

  // ── 陰影 ──（剪影＝描邊＋加粗後的整個字；濃度在層上一次套）
  if (hasShadow) {
    const black = ui.Color(0xFF000000);
    final off = ui.Offset(at.dx + shadowOff, at.dy + shadowOff);
    if (!blurred && spread <= 0) {
      // 硬影、沒描邊沒加粗：剪影就是字形本身，直接畫最省
      layout(
        base.copyWith(color: black.withValues(alpha: t.shadowOpacity)),
      ).paint(canvas, off);
    } else {
      // 描邊跟填字要是各自半透明地疊，交界處 alpha 相乘會出現一圈
      // 更深的框；先不透明畫好剪影，整層再按濃度（＋模糊）合成
      final bounds = inkBox
          .shift(ui.Offset(shadowOff, shadowOff))
          .inflate(inkSlack + spread + sigma * 3);
      final lp = ui.Paint()
        ..color = const ui.Color(0xFFFFFFFF).withValues(alpha: t.shadowOpacity);
      if (blurred) {
        lp.imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: ui.TileMode.decal,
        );
      }
      canvas.saveLayer(bounds, lp);
      if (spread > 0) {
        layout(
          base.copyWith(foreground: strokePaint(spread * 2, black)),
        ).paint(canvas, off);
      }
      layout(base.copyWith(color: black)).paint(canvas, off);
      canvas.restore();
    }
  }

  // ── 描邊 ──（在本體底下；不透明，透明度由整組那層套）
  if (t.outline) {
    layout(
      base.copyWith(
        foreground: strokePaint(outlinePx, Color(t.outlineColorValue)),
      ),
    ).paint(canvas, at);
  }

  // ── 本體 ──（加粗＝同色描邊撐粗，再蓋上填字）
  if (hasBold) {
    layout(
      base.copyWith(foreground: strokePaint(boldPx, bodyOpaque)),
    ).paint(canvas, at);
  }
  fill.paint(canvas, at);

  if (grouped) canvas.restore();
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
        t.weight,
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
