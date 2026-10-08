import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

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

/// 底色塊往版面框外留的白（左右 h、上下 v）。預覽、匯出、包圍盒、
/// 平鋪都拿這一份，改這裡四邊一起動。
/// 橫式的上下本來就有行高的空白（思源黑體一行 1.45 字級、字只佔 1），
/// 所以上下留得比左右少；直式一格剛好一個字身框，四邊都貼著字，
/// 上下也要留跟左右一樣多
({double h, double v}) markBgPadding(TextMark t, double fontSize) {
  final h = fontSize * 0.35 * t.bgPad;
  return (h: h, v: t.vertical ? h : fontSize * 0.18 * t.bgPad);
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
/// [rasterScale] 非 null 時先將一顆文字（含陰影／透明度）烙成小圖再重用。
/// Android 使用這條路，避免密集平鋪產生數百個 GPU 離屏特效層。
/// 預覽傳裝置像素倍率，匯出傳 1（畫布已經是輸出像素）。
void paintTextTiled(
  ui.Canvas canvas,
  TextMark t,
  double fontSize,
  double w,
  double h, {
  double? rasterScale,
}) {
  if (!fontSize.isFinite ||
      fontSize <= 0 ||
      !w.isFinite ||
      !h.isFinite ||
      w <= 0 ||
      h <= 0) {
    return;
  }
  final m = measureMark(t, fontSize);
  final stepX = m.width + fontSize * 2.2;
  final stepY = m.height + fontSize * 2.6;
  // fromJson 有夾 sizeFrac 下限，這裡再守一次：步進 0 就是永不終止
  if (!(stepX > 0) || !(stepY > 0)) return;
  final (h: padH, v: padV) = markBgPadding(t, fontSize);
  final reach = markReach(t, fontSize);
  final stamp = rasterScale == null
      ? null
      : _tiledGlyph(t, fontSize, m, reach, rasterScale);
  final stampPaint = ui.Paint()..filterQuality = ui.FilterQuality.low;
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
      if (stamp == null) {
        paintMarkGlyphs(canvas, t, fontSize, ui.Offset(x, y));
      } else {
        canvas.drawImageRect(
          stamp.image,
          ui.Rect.fromLTWH(
            0,
            0,
            stamp.image.width.toDouble(),
            stamp.image.height.toDouble(),
          ),
          stamp.bounds.shift(ui.Offset(x, y)),
          stampPaint,
        );
      }
    }
  }
  canvas.restore();
}

class _TiledGlyph {
  const _TiledGlyph(this.image, this.bounds);
  final ui.Image image;
  final ui.Rect bounds;
  int get bytes => image.width * image.height * 4;
}

final _tileCache = <Record, _TiledGlyph>{};
int _tileCacheBytes = 0;
const _tileCacheBudget = 4 * 1024 * 1024;

/// 只快取單顆文字，絕不快取整張照片大小的平鋪畫布。
/// 尺寸、樣式或裝置倍率改變就重新畫；旋轉與位置沿用同一張小圖。
_TiledGlyph? _tiledGlyph(
  TextMark t,
  double fontSize,
  Size measured,
  double reach,
  double scale,
) {
  if (!scale.isFinite || scale <= 0) return null;
  final key = (
    text: t.text,
    family: t.fontFamily,
    fontSize: fontSize,
    spacing: t.spacing,
    alignment: t.alignment,
    vertical: t.vertical,
    color: t.colorValue,
    opacity: t.opacity,
    weight: t.weight,
    outline: t.outline,
    outlineWidth: t.outlineWidth,
    outlineColor: t.outlineColorValue,
    shadow: t.shadow,
    shadowOpacity: t.shadowOpacity,
    shadowBlur: t.shadowBlur,
    scale: scale,
  );
  final hit = _tileCache.remove(key);
  if (hit != null) {
    _tileCache[key] = hit;
    return hit;
  }
  // 把邊界對齊實際像素，額外一像素留給邊緣取樣。
  final left = (-reach * scale).floor() - 1;
  final top = left;
  final width = ((measured.width + reach) * scale).ceil() + 1 - left;
  final height = ((measured.height + reach) * scale).ceil() + 1 - top;
  final bytes = width * height * 4;
  // 超大的文字不建立巨型紋理，沿用向量畫法；密集的小字才需要小圖。
  if (width <= 0 ||
      height <= 0 ||
      width > 2048 ||
      height > 2048 ||
      bytes > _tileCacheBudget ~/ 4) {
    return null;
  }
  while (_tileCache.isNotEmpty &&
      (_tileCache.length >= 16 || _tileCacheBytes + bytes > _tileCacheBudget)) {
    final old = _tileCache.remove(_tileCache.keys.first)!;
    _tileCacheBytes -= old.bytes;
    old.image.dispose();
  }
  final bounds = ui.Rect.fromLTWH(
    left / scale,
    top / scale,
    width / scale,
    height / scale,
  );
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)
    ..scale(scale)
    ..translate(-bounds.left, -bounds.top);
  paintMarkGlyphs(canvas, t, fontSize, ui.Offset.zero);
  final picture = recorder.endRecording();
  final ui.Image image;
  try {
    image = picture.toImageSync(width, height);
  } finally {
    picture.dispose();
  }
  final result = _TiledGlyph(image, bounds);
  _tileCache[key] = result;
  _tileCacheBytes += result.bytes;
  return result;
}

/// 測試用：密集平鋪只能重用有界的小圖，不能一格配置一張。
({int entries, int bytes}) get debugTiledGlyphCache =>
    (entries: _tileCache.length, bytes: _tileCacheBytes);

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
  TextAlign alignment,
  bool vertical,
  int color,
  double strokeW,
  int strokeColor,
});

final LinkedHashMap<_GlyphKey, _Laid> _glyphCache = LinkedHashMap();
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
  for (final tile in _tileCache.values) {
    tile.image.dispose();
  }
  _tileCache.clear();
  _tileCacheBytes = 0;
}

/// 測試用：快取裡目前有幾條
int get debugGlyphCacheSize => _glyphCache.length;

_Laid _laidOut(
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
    alignment: t.alignment,
    vertical: t.vertical,
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
    // 直式的字距算在格高裡（[_VerticalLaid]），字本身不另外加
    letterSpacing: t.vertical ? 0 : fontSize * t.spacing,
    // 直式用字型自己的直排字形：「」（）《》…～ 轉成直的。思源黑／宋、
    // 粉圓、文楷、悠哉都帶 vert；拉丁字型的中文落到思源黑體一樣吃得到，
    // 沒帶的字型就照原樣畫
    fontFeatures: t.vertical ? const [ui.FontFeature.enable('vert')] : null,
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
  final _Laid p = t.vertical
      ? _VerticalLaid.layout(t, fontSize, style)
      : _HorizontalLaid(
          TextPainter(
            text: TextSpan(text: t.text, style: style),
            textDirection: TextDirection.ltr,
            textAlign: t.alignment,
          )..layout(),
        );
  _glyphCache[key] = p;
  if (_glyphCache.length > _glyphCacheCap) {
    _glyphCache.remove(_glyphCache.keys.first)!.dispose();
  }
  return p;
}

/// 排好版的一顆文字（本體、陰影、描邊、加粗各一份）
abstract class _Laid {
  double get width;
  double get height;
  void paint(ui.Canvas canvas, ui.Offset at);
  void dispose();
}

/// 橫式：一個 TextPainter 排整段（換行、對齊交給文字引擎）
class _HorizontalLaid implements _Laid {
  _HorizontalLaid(this._p);
  final TextPainter _p;

  @override
  double get width => _p.width;

  @override
  double get height => _p.height;

  @override
  void paint(ui.Canvas canvas, ui.Offset at) => _p.paint(canvas, at);

  @override
  void dispose() => _p.dispose();
}

/// 直式的欄距（相對字級）：欄跟欄之間的空隙。取思源黑體橫式的行距
///（一行 1.45 字級＝字身 1＋空隙 0.45），橫直切換段落的疏密差不多
const double kVerticalColumnGap = 0.45;

/// 沒帶 vert 功能的中文字型（縫合像素）：直式的括號改用 Unicode 的直排
/// 標點字元，字型裡有這些字（省略號沒有，落到思源黑體的直排省略號）
const _kNoVertFeature = {'FusionPixel'};
const _kVerticalForms = {
  '「': '﹁',
  '」': '﹂',
  '『': '﹃',
  '』': '﹄',
  '（': '︵',
  '）': '︶',
  '｛': '︷',
  '｝': '︸',
  '〔': '︹',
  '〕': '︺',
  '【': '︻',
  '】': '︼',
  '《': '︽',
  '》': '︾',
  '〈': '︿',
  '〉': '﹀',
  '…': '︙',
  '—': '︱',
};

/// 字身框（中日韓字那個 1 字級的方框）的中心在基線上方幾個字級。
/// 思源黑／宋、文楷、悠哉的字身框都是基線下 0.12 到基線上 0.88；
/// 拉丁大寫字母的中心（約 0.35）也在這附近
const double _kEmBoxCenter = 0.38;

/// 直式：Flutter 的文字引擎不會直排，這裡自己擺。
/// - 一行＝一欄，第一行在最右邊（由右往左讀）
/// - 一個字（字素叢集：emoji、組合字不會被拆開）一格、字直立不轉；
///   格高＝字級×(1＋間距)，字身框中心對格子中心，左右在欄寬裡置中
/// - 半形空白只佔半格（一整格的洞太大）；全形空白照樣一整格
/// - 對齊：左＝靠上、置中、右＝靠下（短的欄對齊最長的那一欄）
/// 每個字各排一次，整份錄成一張 Picture：平鋪幾百格重播，每格也只是
/// 一次呼叫，不是每格幾十個字
class _VerticalLaid implements _Laid {
  _VerticalLaid._(this._glyphs, this._picture, this.width, this.height);

  factory _VerticalLaid.layout(TextMark t, double fontSize, TextStyle style) {
    final pitch = fontSize * (1 + t.spacing);
    final forms = _kNoVertFeature.contains(t.fontFamily)
        ? _kVerticalForms
        : const <String, String>{};
    final glyphs = <TextPainter>[];
    final cols = <List<({TextPainter? glyph, double h})>>[];
    var colW = fontSize;
    for (final line in t.text.replaceAll('\r', '').split('\n')) {
      final col = <({TextPainter? glyph, double h})>[];
      for (final ch in line.characters) {
        if (ch == '　') {
          col.add((glyph: null, h: pitch));
        } else if (ch.trim().isEmpty) {
          col.add((glyph: null, h: pitch / 2));
        } else {
          final p = TextPainter(
            text: TextSpan(text: forms[ch] ?? ch, style: style),
            textDirection: TextDirection.ltr,
          )..layout();
          glyphs.add(p);
          colW = math.max(colW, p.width);
          col.add((glyph: p, h: pitch));
        }
      }
      cols.add(col);
    }
    final colH = [for (final c in cols) c.fold(0.0, (a, g) => a + g.h)];
    // 至少一格高：橫式的空字串也有一行高，量出來不會是扁的
    final height = colH.fold(pitch, (a, b) => math.max(a, b));
    final gap = fontSize * kVerticalColumnGap;
    final width = cols.length * colW + (cols.length - 1) * gap;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    for (var i = 0; i < cols.length; i++) {
      final x = width - colW - i * (colW + gap);
      var y = switch (t.alignment) {
        TextAlign.center => (height - colH[i]) / 2,
        TextAlign.right => height - colH[i],
        _ => 0.0,
      };
      for (final (:glyph, :h) in cols[i]) {
        if (glyph != null) {
          final base = glyph.computeDistanceToActualBaseline(
            TextBaseline.alphabetic,
          );
          glyph.paint(
            canvas,
            ui.Offset(
              x + (colW - glyph.width) / 2,
              y + h / 2 + fontSize * _kEmBoxCenter - base,
            ),
          );
        }
        y += h;
      }
    }
    return _VerticalLaid._(glyphs, rec.endRecording(), width, height);
  }

  /// 錄進 Picture 的字：Picture 已經自己留著字形，這些留著只是保險，
  /// 跟 Picture 同生同死
  final List<TextPainter> _glyphs;
  final ui.Picture _picture;

  @override
  final double width;

  @override
  final double height;

  @override
  void paint(ui.Canvas canvas, ui.Offset at) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.drawPicture(_picture);
    canvas.restore();
  }

  @override
  void dispose() {
    _picture.dispose();
    for (final p in _glyphs) {
      p.dispose();
    }
  }
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
        t.alignment,
        t.vertical,
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
