import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/widgets/watermark_layer.dart';
import 'package:markcut/widgets/watermark_panel.dart';

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

/// 圖片解碼是非同步的，等它畫出來
Future<void> _settle(WidgetTester t, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  // 迴歸守門：批次浮水印畫面「點了面板的圖片縮圖（琥珀亮框）之後，
  // 圖片在預覽上拖不動」。
  //
  // 成因：文字圖層畫在圖片圖層之後（＝疊在上面）而且 HitTestBehavior
  // .opaque，預設文字跟剛加進來的圖片又都在正中央，手指落在重疊處
  // 全被文字吃掉；能讓被選部件在整個預覽上都拖得動的「選取路由」
  // 只有在畫面有選取（_wmPart）時才掛，而面板的縮圖亮框以前只改
  // settings.activeLogo，從來沒告訴畫面「現在選的是圖片」
  testWidgets('批次：在面板選了圖片之後，預覽上拖得動它（文字不會被拖走）', (t) async {
    SharedPreferences.setMockInitialValues({});
    late Uint8List photo, logoPng;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF204060), 400);
      logoPng = await _png(const Color(0xFFFF0000), 100);
    });

    // 真實情境：預設文字在正中央，剛加進來的圖片也在正中央
    final s = WatermarkSettings();
    expect(s.text.x, 0.5);
    expect(s.text.y, 0.5);
    s.logo
      ..enabled = true
      ..bytesValue = logoPng
      ..sizeFrac = 0.32
      ..x = 0.5
      ..y = 0.5;

    await t.pumpWidget(
      MaterialApp(
        home: BatchWatermarkScreen(
          files: [XFile.fromData(photo, name: 'a.png', mimeType: 'image/png')],
          restore: {'settings': s.toJson()},
        ),
      ),
    );
    await _settle(t);

    final layerFinder = find.byType(WatermarkLayer);
    expect(layerFinder, findsOneWidget);
    WatermarkSettings live() => t.widget<WatermarkLayer>(layerFinder).settings;

    // 面板切到「圖片」分頁，點縮圖列那一張（＝畫面上的琥珀選取）
    await t.tap(find.text('圖片'));
    await t.pumpAndSettle();
    final thumb = find.descendant(
      of: find.byType(WatermarkPanel),
      matching: find.byType(Image),
    );
    expect(thumb, findsOneWidget, reason: '圖片分頁裡應該只有那一張縮圖是 Image');
    await t.tap(thumb);
    await t.pumpAndSettle();

    final logoBefore = (live().logo.x, live().logo.y);
    final textBefore = (live().text.x, live().text.y);

    // 從圖片中心往右下拖（正是被文字蓋住的那一塊）
    final r = t.getRect(layerFinder);
    final start = Offset(
      r.left + r.width * logoBefore.$1,
      r.top + r.height * logoBefore.$2,
    );
    final g = await t.startGesture(start);
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(6, 6));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump();

    expect(
      live().logo.x,
      greaterThan(logoBefore.$1 + 0.05),
      reason: '選取中的圖片要跟著手指走',
    );
    expect(live().logo.y, greaterThan(logoBefore.$2 + 0.05));
    // 拖的是圖片，文字一動都不能動
    expect(live().text.x, textBefore.$1);
    expect(live().text.y, textBefore.$2);
  });

  // 迴歸守門：放大預覽時 AppBar 整個收掉，右上角那兩顆（縮放、原始）
  // 就跟時鐘／瀏海重疊了
  testWidgets('批次：放大預覽時右上角兩顆在安全區內，非放大時版面不變', (t) async {
    SharedPreferences.setMockInitialValues({});
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF204060), 400);
    });

    // 瀏海：實體 94px ÷ DPR 2 ＝ 47 邏輯像素
    t.view.devicePixelRatio = 2.0;
    t.view.padding = const FakeViewPadding(top: 94);
    addTearDown(t.view.reset);

    await t.pumpWidget(
      MaterialApp(
        home: BatchWatermarkScreen(
          files: [XFile.fromData(photo, name: 'a.png', mimeType: 'image/png')],
        ),
      ),
    );
    await _settle(t);

    const inset = 47.0;
    // 非放大：AppBar 在，兩顆貼在預覽區左上（AppBar 底下）＋6 的留白。
    // SafeArea 在這裡必須是 0——Scaffold 已經把上緣內距從 body 拿掉了
    final appBarBottom = t.getRect(find.byType(AppBar)).bottom;
    expect(appBarBottom, greaterThan(inset));
    expect(
      t.getRect(find.byIcon(Icons.fullscreen)).top,
      closeTo(appBarBottom + 6 + 5, 0.01),
      reason: '非放大狀態的位置不能因為 SafeArea 而改變（6＝外距、5＝內距）',
    );

    // 放大：AppBar 收掉，預覽頂到螢幕最上緣——兩顆要被推到瀏海下面
    await t.tap(find.byIcon(Icons.fullscreen));
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(
      t.getRect(find.byIcon(Icons.fullscreen_exit)).top,
      greaterThanOrEqualTo(inset),
      reason: '放大預覽的縮放鈕不能壓在狀態列上',
    );
    expect(
      t.getRect(find.text('原始')).top,
      greaterThanOrEqualTo(inset),
      reason: '放大預覽的「原始」比例鈕不能壓在狀態列上',
    );
  });
}
