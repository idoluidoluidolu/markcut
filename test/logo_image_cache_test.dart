// Logo 只解一次：預覽圖層、平鋪層、匯出拿的是同一個 ui.Image
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/logo_mark_painter.dart';
import 'package:markcut/widgets/watermark_layer.dart';

Future<Uint8List> _png(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF00FF00),
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('大圖預覽限制解碼尺寸，匯出保留原始解析度', () async {
    final bytes = await _png(2400, 1200);
    final preview = await logoImageFor(bytes, maxSide: kLogoPreviewMaxSide);
    expect((preview.width, preview.height), (1080, 540));
    expect(logoImageCached(bytes), isNull);
    final original = await logoImageFor(bytes);
    expect((original.width, original.height), (2400, 1200));
    expect(
      identical(preview, await logoImageFor(bytes, maxSide: 1080)),
      isTrue,
    );
  });

  test('多張圖片副本共用 bytes，替換 b64 不沿用舊快取', () async {
    final settings = WatermarkSettings();
    settings.logos.clear();
    for (var i = 0; i < 5; i++) {
      settings.logos.add(LogoMark()..bytesValue = await _png(40 + i, 10));
    }
    final copy = settings.copy();
    for (var i = 0; i < 5; i++) {
      expect(identical(settings.logos[i].bytes, copy.logos[i].bytes), isTrue);
    }
    final old = copy.logos[0].bytes;
    copy.logos[0].b64 = copy.logos[4].b64;
    expect(copy.logos[0].bytes, isNot(equals(old)));
    expect(copy.logos[0].bytes, equals(copy.logos[4].bytes));
  });

  test('同一份 bytes 同時要三次，只解一次、拿到同一個物件', () async {
    final bytes = await _png(40, 10);
    expect(logoImageCached(bytes), isNull);
    final f1 = logoImageFor(bytes);
    final f2 = logoImageFor(bytes);
    expect(identical(f1, f2), isTrue, reason: '正在解的一起等同一個 Future');
    final a = await f1;
    final b = await f2;
    final c = await logoImageFor(bytes);
    expect(identical(a, b), isTrue);
    expect(identical(a, c), isTrue);
    expect(identical(logoImageCached(bytes), a), isTrue);
    expect((a.width, a.height), (40, 10));
    // 同內容、不同物件＝另一顆（鍵是物件身分，跟 base64 池子同一套）
    final other = Uint8List.fromList(bytes);
    expect(logoImageCached(other), isNull);
  });

  testWidgets('預覽圖層：兩層同一顆 Logo，共用同一個解碼結果、長寬比對', (t) async {
    // 一定要包 runAsync：Picture.toImage 是真的非同步，在 testWidgets 的
    // 假時鐘裡 await 它而且還沒 pump 過，微任務永遠不會被推進＝整支卡死
    late Uint8List png;
    await t.runAsync(() async => png = await _png(200, 50));
    final s = WatermarkSettings();
    s.logo
      ..enabled = true
      ..bytesValue = png
      ..sizeFrac = 0.4;
    final s2 = s.copy();
    expect(identical(s.logo.bytes, s2.logo.bytes), isTrue, reason: 'bytes 池子');

    // Center 包著才有寬鬆約束，SizedBox 才真的是 400×400
    //（直接當 home 會被螢幕的緊約束撐滿，短邊就不是 400 了）
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: Stack(
              children: [
                WatermarkLayer(settings: s, onChanged: () {}),
                WatermarkLayer(settings: s2, onChanged: () {}),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 30));
    }
    final img = logoImageCached(s.logo.bytes!, maxSide: kLogoPreviewMaxSide);
    expect(img, isNotNull);
    // 兩層各畫一顆，畫家拿的都是快取那一個
    final painters = t
        .widgetList<CustomPaint>(
          find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is LogoUnitPainter,
          ),
        )
        .map((w) => w.painter! as LogoUnitPainter)
        .toList();
    expect(painters.length, 2);
    for (final p in painters) {
      expect(identical(p.img, img), isTrue);
    }
    // 長寬比 4:1：寬 0.4×400=160、高 40（量錯會變 160）
    final unit = t.getSize(
      find
          .byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is LogoUnitPainter,
          )
          .first,
    );
    expect(unit.width, closeTo(160, 0.5));
    expect(unit.height, closeTo(40, 0.5));
  });
}
