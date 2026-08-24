import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/logo_mark_painter.dart';
import 'package:markcut/services/watermark_renderer.dart';
import 'package:markcut/widgets/watermark_layer.dart';

Future<Uint8List> _png(Color c, int side) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..color = c,
  );
  final img = await rec.endRecording().toImage(side, side);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

void main() {
  testWidgets('多張圖片：每一張都畫出來，點哪張哪張就變成操作中', (t) async {
    late Uint8List a, b;
    await t.runAsync(() async {
      a = await _png(const Color(0xFFFF0000), 100);
      b = await _png(const Color(0xFF0000FF), 100);
    });

    final s = WatermarkSettings();
    s.text.enabled = false;
    // 第一張：左上；第二張：右下。都用正方形，長寬比不必等解碼
    s.logo
      ..enabled = true
      ..bytesValue = a
      ..sizeFrac = 0.2
      ..x = 0.25
      ..y = 0.25;
    s.addLogo()
      ..bytesValue = b
      ..sizeFrac = 0.2
      ..x = 0.75
      ..y = 0.75;
    s.activeLogo = 0;

    var selected = WmPart.none;
    await t.pumpWidget(
      MaterialApp(
        // 貼左上角：這樣測試裡的座標就等於圖層裡的座標
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 400,
            child: WatermarkLayer(
              settings: s,
              onChanged: () {},
              selectedPart: WmPart.logo,
              onSelectPart: (p) => selected = p,
            ),
          ),
        ),
      ),
    );
    // 圖片是非同步解碼的，沒解完 Image 的高是 0＝點不到
    for (var i = 0; i < 8; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump(const Duration(milliseconds: 40));
    }

    // 圖片內容改由共用畫家（LogoUnitPainter）畫，不再是 Image widget
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is LogoUnitPainter,
      ),
      findsNWidgets(2),
      reason: '兩張圖都要畫出來',
    );

    // 右下那張（第二張）：中心在 (300, 300)
    await t.tapAt(const Offset(300, 300));
    // 圖層同時吃雙擊（雙擊＝回正中央），單擊要等雙擊的時間窗過了才成立
    await t.pump(const Duration(milliseconds: 400));
    expect(selected, WmPart.logo);
    expect(s.activeLogo, 1, reason: '點到第二張，它就該變成操作中的那張');

    // 再點左上那張，操作對象要換回去
    await t.tapAt(const Offset(100, 100));
    await t.pump(const Duration(milliseconds: 400));
    expect(s.activeLogo, 0);

    // 從第一張圖上拖：只動它，第二張留在原地
    final ax = s.logos[0].x;
    final bx = s.logos[1].x, by = s.logos[1].y;
    await t.dragFrom(const Offset(100, 100), const Offset(40, 0));
    await t.pump();
    expect(s.logos[0].x > ax, isTrue, reason: '被拖的那張要跟著手指走');
    expect(s.logos[1].x, bx, reason: '沒被拖到的那張不能動');
    expect(s.logos[1].y, by);

    // 雙擊辨識器會留一個計時器，不等它過去會被判定「還有 timer 沒收」
    await t.pump(const Duration(milliseconds: 500));
  });

  testWidgets('匯出用的整版 PNG：每一張圖片都畫得進去', (t) async {
    late Uint8List png;
    await t.runAsync(() async {
      final s = WatermarkSettings();
      s.text.enabled = false;
      s.logo
        ..enabled = true
        ..bytesValue = await _png(const Color(0xFFFF0000), 40)
        ..opacity = 1
        ..sizeFrac = 0.2
        ..x = 0.25
        ..y = 0.25;
      s.addLogo()
        ..bytesValue = await _png(const Color(0xFF00FF00), 40)
        ..opacity = 1
        ..sizeFrac = 0.2
        ..x = 0.75
        ..y = 0.75;
      png = await WatermarkRenderer.renderOverlayPng(s, 400, 400);
    });

    late ui.Image img;
    await t.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png);
      img = (await codec.getNextFrame()).image;
    });
    late ByteData data;
    await t.runAsync(() async {
      data = (await img.toByteData())!;
    });

    int pixelAt(int x, int y) => data.getUint32((y * img.width + x) * 4);
    // 兩張圖的中心各自要是自己的顏色（RGBA 排列）
    expect(pixelAt(100, 100), 0xFF0000FF, reason: '第一張圖沒畫出來');
    expect(pixelAt(300, 300), 0x00FF00FF, reason: '第二張圖沒畫出來');
    img.dispose();
  });
}
