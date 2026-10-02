// 平鋪文字的共用畫家（paintTextTiled）：預覽跟匯出以前各抄一份迴圈，
// 現在只有一份，而且會略過「整格落在畫面外」的格子。略過只能省時間，
// 不能改輸出——這裡拿沒有略過的暴力版逐像素比
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/text_mark_painter.dart';

class _CountingCanvas implements ui.Canvas {
  int layers = 0;
  int stamps = 0;

  @override
  void saveLayer(ui.Rect? bounds, ui.Paint paint) => layers++;
  @override
  void drawImageRect(
    ui.Image image,
    ui.Rect src,
    ui.Rect dst,
    ui.Paint paint,
  ) => stamps++;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 舊版迴圈（不略過任何格子）
void _reference(
  ui.Canvas canvas,
  TextMark t,
  double fontSize,
  double w,
  double h,
) {
  final m = measureMark(t, fontSize);
  final stepX = m.width + fontSize * 2.2;
  final stepY = m.height + fontSize * 2.6;
  final padH = fontSize * 0.35 * t.bgPad;
  final padV = fontSize * 0.18 * t.bgPad;
  canvas.save();
  canvas.clipRect(ui.Rect.fromLTWH(0, 0, w, h));
  if (t.rotation.abs() > 0.01) {
    canvas.translate(w / 2, h / 2);
    canvas.rotate(t.rotation * 3.141592653589793 / 180);
    canvas.translate(-w / 2, -h / 2);
  }
  var row = 0;
  for (var y = -h; y < h * 2; y += stepY, row++) {
    final shift = row.isOdd ? stepX / 2 : 0.0;
    for (var x = -w - shift; x < w * 2; x += stepX) {
      if (t.bg) {
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
      paintMarkGlyphs(canvas, t, fontSize, ui.Offset(x, y));
    }
  }
  canvas.restore();
}

Future<ByteData> _render(void Function(ui.Canvas) draw, int w, int h) async {
  final rec = ui.PictureRecorder();
  draw(ui.Canvas(rec));
  final img = await rec.endRecording().toImage(w, h);
  final raw = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  img.dispose();
  return raw;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(clearGlyphCache);

  test('Android 密集平鋪只烙一顆字，不為每格建立特效層', () {
    clearGlyphCache();
    final mark = TextMark(
      text: 'M',
      tiled: true,
      sizeFrac: 0.015,
      outline: true,
      shadowBlur: 0.15,
    );
    final canvas = _CountingCanvas();
    paintTextTiled(canvas, mark, 6, 390, 844, rasterScale: 3);
    expect(canvas.stamps, greaterThan(300));
    expect(canvas.layers, 0);
    expect(debugTiledGlyphCache.entries, 1);
    final bytes = debugTiledGlyphCache.bytes;
    paintTextTiled(canvas, mark, 6, 390, 844, rasterScale: 3);
    expect(debugTiledGlyphCache, (entries: 1, bytes: bytes));
    mark.text = 'Changed';
    paintTextTiled(canvas, mark, 6, 390, 844, rasterScale: 3);
    expect(debugTiledGlyphCache.entries, 2, reason: '修改文字不能沿用舊的小圖');
    for (var i = 0; i < 24; i++) {
      mark.opacity = (i + 1) / 25;
      paintTextTiled(canvas, mark, 6, 390, 844, rasterScale: 3);
    }
    expect(debugTiledGlyphCache.entries, lessThanOrEqualTo(16));
    expect(debugTiledGlyphCache.bytes, lessThanOrEqualTo(4 * 1024 * 1024));
    clearGlyphCache();
    expect(debugTiledGlyphCache, (entries: 0, bytes: 0));
  });

  for (final rotation in [0.0, 37.0]) {
    test('平鋪小圖保留字形、透明度、陰影和排列（$rotation 度）', () async {
      final mark = TextMark(
        text: 'Mark',
        tiled: true,
        rotation: rotation,
        opacity: 0.6,
        outline: true,
        shadowBlur: 0.12,
      );
      const w = 320, h = 200;
      final actual = await _render(
        (c) => paintTextTiled(
          c,
          mark,
          20,
          w.toDouble(),
          h.toDouble(),
          rasterScale: 3,
        ),
        w,
        h,
      );
      final expected = await _render(
        (c) => _reference(c, mark, 20, w.toDouble(), h.toDouble()),
        w,
        h,
      );
      var actualAlpha = 0, expectedAlpha = 0, totalError = 0;
      for (var i = 0; i < actual.lengthInBytes; i++) {
        totalError += (actual.getUint8(i) - expected.getUint8(i)).abs();
        if (i % 4 == 3) {
          actualAlpha += actual.getUint8(i);
          expectedAlpha += expected.getUint8(i);
        }
      }
      expect(actualAlpha, greaterThan(10000));
      expect(actualAlpha / expectedAlpha, closeTo(1, 0.05));
      expect(
        totalError / actual.lengthInBytes,
        lessThan(3),
        reason: '小圖取樣可有邊緣誤差，但不能漏字、位移或重複套透明度',
      );
    });
  }

  for (final (name, t) in [
    (
      '轉 37 度＋底色＋陰影模糊＋描邊',
      TextMark(
        text: '@MarkCut 浮水印',
        sizeFrac: 0.06,
        tiled: true,
        rotation: 37,
        bg: true,
        bgPad: 1.6,
        shadow: true,
        shadowBlur: 0.15,
        outline: true,
        outlineWidth: 0.12,
        opacity: 0.6,
      ),
    ),
    ('不轉、硬影', TextMark(text: 'abc', sizeFrac: 0.05, tiled: true)),
    (
      '轉 -120 度、大字',
      TextMark(
        text: '大',
        sizeFrac: 0.3,
        tiled: true,
        rotation: -120,
        weight: 1,
      ),
    ),
  ]) {
    test('平鋪略過畫面外的格子：輸出跟暴力版一字不差（$name）', () async {
      const w = 320, h = 200;
      final fontSize = t.sizeFrac * 200;
      final a = await _render(
        (c) => paintTextTiled(c, t, fontSize, w.toDouble(), h.toDouble()),
        w,
        h,
      );
      final b = await _render(
        (c) => _reference(c, t, fontSize, w.toDouble(), h.toDouble()),
        w,
        h,
      );
      expect(a.lengthInBytes, b.lengthInBytes);
      var diff = 0;
      var painted = 0;
      for (var i = 0; i < a.lengthInBytes; i++) {
        if (a.getUint8(i) != b.getUint8(i)) diff++;
        if (i % 4 == 3 && b.getUint8(i) != 0) painted++;
      }
      expect(painted, greaterThan(100), reason: '$name：要真的有畫到東西');
      expect(diff, 0, reason: '$name：略過的格子不能改變任何像素');
    });
  }

  test('排版快取：同一顆字重複畫不會長，換字級才多一條', () {
    clearGlyphCache();
    final t = TextMark(text: 'cache', sizeFrac: 0.1, outline: true);
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    paintMarkGlyphs(c, t, 40, ui.Offset.zero);
    final after1 = debugGlyphCacheSize;
    expect(after1, greaterThan(0));
    for (var i = 0; i < 50; i++) {
      paintMarkGlyphs(c, t, 40, ui.Offset(i.toDouble(), 0));
    }
    expect(debugGlyphCacheSize, after1, reason: '同一份設定只排一次');
    paintMarkGlyphs(c, t, 41, ui.Offset.zero);
    expect(debugGlyphCacheSize, greaterThan(after1));
    // 上限：不會無限長
    for (var i = 0; i < 300; i++) {
      paintMarkGlyphs(c, t, 50 + i.toDouble(), ui.Offset.zero);
    }
    expect(debugGlyphCacheSize, lessThanOrEqualTo(96));
    rec.endRecording().dispose();
  });
}
