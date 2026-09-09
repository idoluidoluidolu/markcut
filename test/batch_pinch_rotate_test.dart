// 迴歸守門：批次浮水印畫面「圖片無法在畫面上用手指旋轉」。
//
// 以前批次頁預覽的雙指手勢只做縮放，旋轉只能拉面板的滑桿；
// 照片／影片／工作室三個畫面都是兩指轉多少是多少（15 度吸附，見
// RotationSnap）。這裡把兩指繞著預覽中心轉 90 度，文字跟圖片都要
// 轉到 90 度、大小一格都不能動（純旋轉，兩指距離沒變）。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/batch_watermark_screen.dart';
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
  testWidgets('批次：預覽上兩指繞中心轉 90 度，文字與圖片一起轉到 90°、大小不變', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    late Uint8List photo, logoPng;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF204060), 400);
      logoPng = await _png(const Color(0xFFFF0000), 100);
    });

    // 真實情境：預設文字在正中央，剛加進來的圖片也在正中央、都沒選取
    final s = WatermarkSettings();
    expect(s.text.enabled && s.text.text.trim().isNotEmpty, isTrue);
    s.logo
      ..enabled = true
      ..bytesValue = logoPng
      ..sizeFrac = 0.32;

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
    expect(live().text.rotation, 0);
    expect(live().logo.rotation, 0);
    final textSize = live().text.sizeFrac;
    final logoSize = live().logo.sizeFrac;

    // 兩指落在文字／圖片外面（半徑 110，圖片半寬 62），繞著預覽中心
    // 從水平轉到垂直：每格 6 度，跟真機一格一個指針事件一樣
    final c = t.getRect(layerFinder).center;
    const radius = 110.0;
    Offset at(double deg, double sign) {
      final a = deg * math.pi / 180;
      return c + Offset(math.cos(a), math.sin(a)) * (radius * sign);
    }

    final a = await t.startGesture(at(0, -1));
    final b = await t.startGesture(at(0, 1));
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 1; i <= 15; i++) {
      final deg = 6.0 * i;
      await a.moveTo(at(deg, -1));
      await b.moveTo(at(deg, 1));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await t.pump();

    expect(live().logo.rotation, closeTo(90, 0.01), reason: '圖片要跟著兩指轉');
    expect(live().text.rotation, closeTo(90, 0.01), reason: '沒選取時文字一起轉');
    // 兩指距離沒變：大小一格都不能動
    expect(live().logo.sizeFrac, closeTo(logoSize, 1e-9));
    expect(live().text.sizeFrac, closeTo(textSize, 1e-9));
    expect(t.takeException(), isNull);
  });
}
