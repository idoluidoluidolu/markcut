import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/batch_watermark_screen.dart';

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

Future<void> _pumpBatch(WidgetTester t, List<XFile> files) async {
  SharedPreferences.setMockInitialValues({});
  await t.pumpWidget(MaterialApp(home: BatchWatermarkScreen(files: files)));
  await _settle(t);
  expect(find.text('匯出'), findsOneWidget);
}

void main() {
  // 迴歸守門：批次浮水印按「匯出」只能跳一個視窗。
  //
  // 以前這裡會先跳一個「畫質」視窗（跟影片編輯器同一款、列各檔位的
  // MB），不管這批有沒有影片都問，再跳照片格式——純照片的批次要連按
  // 兩個視窗（實測回報「第一個是影片的，請移除」）。畫質視窗拿掉：
  // 照片固定 JPEG 92（跟單張編輯器一樣）、影片照來源位元率自動挑
  late Uint8List photo;

  setUp(() async {
    photo = await _png(const Color(0xFF204060), 64);
  });

  testWidgets('批次（純照片）：按匯出只跳「輸出到相簿」這一個視窗', (t) async {
    await _pumpBatch(t, [
      XFile.fromData(photo, name: 'a.png', mimeType: 'image/png'),
      XFile.fromData(photo, name: 'b.png', mimeType: 'image/png'),
    ]);

    await t.tap(find.text('匯出'));
    await t.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget, reason: '一次只能跳一個視窗');
    expect(find.text('輸出到相簿'), findsOneWidget, reason: '跳的要是照片格式那個');
    expect(find.text('JPEG'), findsOneWidget);
    expect(find.text('PNG 無損'), findsOneWidget);
    expect(find.text('畫質'), findsNothing, reason: '影片編輯器那個畫質視窗不該出現');
    expect(find.textContaining('MB'), findsNothing);

    // 點外面＝取消，不能開始匯出
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('批次匯出中…'), findsNothing);
  });

  testWidgets('批次（照片＋影片混合）：按匯出也只跳照片格式，沒有畫質視窗', (t) async {
    await _pumpBatch(t, [
      XFile.fromData(photo, name: 'a.png', mimeType: 'image/png'),
      // 測試環境沒有原生解碼；批次頁抽不到縮圖只會留空格，不會炸
      XFile.fromData(Uint8List(32), name: 'v.mp4', mimeType: 'video/mp4'),
    ]);

    await t.tap(find.text('匯出'));
    await t.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget, reason: '一次只能跳一個視窗');
    expect(find.text('輸出到相簿'), findsOneWidget);
    expect(find.text('畫質'), findsNothing, reason: '影片編輯器那個畫質視窗不該出現');
    expect(find.text('省空間'), findsNothing);
    expect(find.text('最高畫質'), findsNothing);
  });
}
