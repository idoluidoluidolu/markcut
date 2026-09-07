import 'dart:collection';
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

  final bodyOpaque = t.colorValue;
  final fill = _laidOut(t, fontSize, color: bodyOpaque);
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
    const black = 0xFF000000;
    final off = ui.Offset(at.dx + shadowOff, at.dy + shadowOff);
    if (!blurred && spread <= 0) {
      // 硬影、沒描邊沒加粗：剪影就是字形本身，直接畫最省
      _laidOut(
        t,
        fontSize,
        color: const ui.Color(
          black,
        ).withValues(alpha: t.shadowOpacity).toARGB32(),
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
        _laidOut(
          t,
          fontSize,
          strokeW: spread * 2,
          strokeColor: black,
        ).paint(canvas, off);
      }
      _laidOut(t, fontSize, color: black).paint(canvas, off);
      canvas.restore();
    }
  }

  // ── 描邊 ──（在本體底下；不透明，透明度由整組那層套）
  if (t.outline) {
    _laidOut(
      t,
      fontSize,
      strokeW: outlinePx,
      strokeColor: t.outlineColorValue,
    ).paint(canvas, at);
  }

  // ── 本體 ──（加粗＝同色描邊撐粗，再蓋上填字）
  if (hasBold) {
    _laidOut(
      t,
      fontSize,
      strokeW: boldPx,
      strokeColor: bodyOpaque,
    ).paint(canvas, at);
  }
  fill.paint(canvas, at);

  if (grouped) canvas.restore();
}

/// 量文字的版面大小（跟 [paintMarkGlyphs] 同一套字型參數；同一份快取）
Size measureMark(TextMark t, double fontSize) {
  final p = _laidOut(t, fontSize, color: t.colorValue);
  return Size(p.width, p.height);
}

/// 一顆文字的內容最多畫到版面框外多遠（陰影／描邊／加粗／墨水餘裕）。
/// 是 [paintMarkGlyphs] 裡離屏層邊界的同一組算式（inkSlack 0.3、加粗
/// 0.06、陰影位移 0.03、模糊 3σ）：那邊的內容最多畫到層邊界為止，所以
/// 這個量一定包得住。包圍盒（WatermarkRenderer.textMarkBounds）跟平鋪的
/// 「整格在畫面外就不畫」都拿它算；改那邊的常數要一起改這裡
///（test/wm_part_bbox_test.dart 會抓「框包不住」）
double markReach(TextMark t, double fontSize) {
  final boldPx = t.weight > 0.005 ? fontSize * 0.06 * t.weight : 0.0;
  final outlinePx = t.outline ? fontSize * t.outlineWidth + boldPx : 0.0;
  final hasShadow = t.shadow && t.shadowOpacity > 0.01;
  final sigma = hasShadow ? fontSize * t.shadowBlur : 0.0;
  final spread = math.max(outlinePx, boldPx) / 2;
  return fontSize * 0.3 +
      spread +
      (hasShadow ? fontSize * 0.03 + sigma * 3 : 0.0);
}

/// [r] 以 [c] 為軸轉 [deg] 度之後的軸對齊包圍盒。角度小到畫的時候
/// 不會轉的（門檻跟畫家一樣 0.01°），這裡也不轉
ui.Rect rotatedRectBounds(ui.Rect r, ui.Offset c, double deg) {
  if (deg.abs() <= 0.01) return r;
  final a = deg * math.pi / 180;
  final ca = math.cos(a), sa = math.sin(a);
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final p in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
    final dx = p.dx - c.dx, dy = p.dy - c.dy;
    final x = c.dx + dx * ca - dy * sa;
    final y = c.dy + dx * sa + dy * ca;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
  }
  return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// 滿版平鋪（棋盤格）：整面交錯重複，忽略 x/y。
/// 預覽（WatermarkLayer 的平鋪畫家）與匯出（WatermarkRenderer）都執行
/// 這一個函式——以前兩邊各抄一份迴圈。字級基準由呼叫端給（短邊）。
///
/// 排法：步進＝版面加固定倍數的字級、奇數列半格錯開、整面以畫布中心
/// 旋轉。迴圈從 -w 走到 2w、-h 走到 2h（轉了角度之後四角才蓋得到），
/// 九倍面積裡真正看得到的只有中間那一塊——「整格落在畫面外」的格子
/// 直接略過，不然每幀白白 paint 上千次。略過的判定用格子的最大外擴
///（底色 padding＋[markReach]）對「畫面在旋轉座標系裡的外接框」，
/// 被略過的格子本來就一個像素都畫不進畫面，輸出一字不差
void paintTextTiled(
  ui.Canvas canvas,
  TextMark t,
  double fontSize,
  double w,
  double h,
) {
  final m = measureMark(t, fontSize);
  final stepX = m.width + fontSize * 2.2;
  final stepY = m.height + fontSize * 2.6;
  // fromJson 有夾 sizeFrac 下限，這裡再守一次：步進 0 就是永不終止
  if (!(stepX > 0) || !(stepY > 0)) return;
  final padH = fontSize * 0.35 * t.bgPad;
  final padV = fontSize * 0.18 * t.bgPad;
  final reach = markReach(t, fontSize);
  canvas.save();
  canvas.clipRect(ui.Rect.fromLTWH(0, 0, w, h));
  var visible = ui.Rect.fromLTWH(0, 0, w, h);
  if (t.rotation.abs() > 0.01) {
    canvas.translate(w / 2, h / 2);
    canvas.rotate(t.rotation * math.pi / 180);
    canvas.translate(-w / 2, -h / 2);
    // 畫面在「轉過的座標系」裡佔的範圍＝畫面反轉回去的外接框
    visible = rotatedRectBounds(visible, ui.Offset(w / 2, h / 2), -t.rotation);
  }
  final cellW = m.width + 2 * (padH + reach);
  final cellH = m.height + 2 * (padV + reach);
  final bgPaint = t.bg
      ? (ui.Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity))
      : null;
  var row = 0;
  for (var y = -h; y < h * 2; y += stepY, row++) {
    final shift = row.isOdd ? stepX / 2 : 0.0;
    for (var x = -w - shift; x < w * 2; x += stepX) {
      final cell = ui.Rect.fromLTWH(
        x - padH - reach,
        y - padV - reach,
        cellW,
        cellH,
      );
      if (!cell.overlaps(visible)) continue;
      if (bgPaint != null) {
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
          bgPaint,
        );
      }
      paintMarkGlyphs(canvas, t, fontSize, ui.Offset(x, y));
    }
  }
  canvas.restore();
}

// ===== 排版快取 =====
//
// 一顆文字每 paint 一次要排版 2～5 次（本體、陰影、描邊、加粗各一個
// TextPainter），平鋪一面約 300 格＝每幀上千次 layout——拖曳、拉滑桿、
// 匯出都吃這個。同一份（文字、字型、字級、字距、顏色／描邊）排一次
// 之後存起來，之後只 paint 不 layout；平鋪的 300 格共用同幾個。
// TextPainter 的「只換顏色／foreground」在框架裡一樣要重建段落再排一次，
// 所以每個變體各存一份，不能共用一個換 text。
// 鍵用 record（結構相等）；容量有上限、最久沒用的先丟；系統字型變動
//（web 的字型是非同步載的，載好會通知）整個清掉，不然會抱著後備字排的版

typedef _GlyphKey = ({
  String text,
  String family,
  double fontSize,
  double spacing,
  int color,
  double strokeW,
  int strokeColor,
});

final LinkedHashMap<_GlyphKey, TextPainter> _glyphCache = LinkedHashMap();
const int _glyphCacheCap = 96;
bool _glyphCacheHooked = false;

void _hookSystemFonts() {
  if (_glyphCacheHooked) return;
  _glyphCacheHooked = true;
  try {
    PaintingBinding.instance.systemFonts.addListener(clearGlyphCache);
  } catch (_) {
    // 沒有 binding（純 Dart 測試）：沒有字型事件可聽，快取照用
  }
}

/// 清掉排版快取（字型換了、測試之間）
void clearGlyphCache() {
  for (final p in _glyphCache.values) {
    p.dispose();
  }
  _glyphCache.clear();
}

/// 測試用：快取裡目前有幾條
int get debugGlyphCacheSize => _glyphCache.length;

TextPainter _laidOut(
  TextMark t,
  double fontSize, {
  int color = 0,
  double strokeW = 0,
  int strokeColor = 0,
}) {
  final key = (
    text: t.text,
    family: t.fontFamily,
    fontSize: fontSize,
    spacing: t.spacing,
    color: strokeW > 0 ? 0 : color,
    strokeW: strokeW,
    strokeColor: strokeW > 0 ? strokeColor : 0,
  );
  final hit = _glyphCache.remove(key);
  if (hit != null) {
    _glyphCache[key] = hit; // 移到最尾＝最近用過
    return hit;
  }
  _hookSystemFonts();
  final style = TextStyle(
    fontFamily: t.fontFamily,
    fontFamilyFallback: kMarkFontFallback,
    fontSize: fontSize,
    letterSpacing: fontSize * t.spacing,
    color: strokeW > 0 ? null : Color(color),
    foreground: strokeW > 0
        ? (ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = strokeW
            ..strokeJoin = ui.StrokeJoin.round
            ..strokeCap = ui.StrokeCap.round
            ..color = Color(strokeColor))
        : null,
  );
  final p = TextPainter(
    text: TextSpan(text: t.text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();
  _glyphCache[key] = p;
  if (_glyphCache.length > _glyphCacheCap) {
    _glyphCache.remove(_glyphCache.keys.first)!.dispose();
  }
  return p;
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
