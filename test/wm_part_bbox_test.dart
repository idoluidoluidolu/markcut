// 包圍盒烘圖（WatermarkRenderer.renderPart）的體檢：
// 1. 裁下來的那一塊擺回原位＝整版烘圖（逐像素，同一個像素格）
// 2. 整版烘圖裡所有非透明像素都落在包圍盒內（陰影／描邊／底色／
//    旋轉／加粗都包得住——這一條抓的是「框算小了」）
// 3. 順便量一版的位元組數（S1 驗收：典型文字浮水印一版 < 300KB）
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/watermark_renderer.dart';

Future<Uint8List> _solidPng(ui.Color c, int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = c,
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

/// 整版 raw 跟包圍盒 raw 比：包圍盒內逐像素相等、包圍盒外整版必須全透明
Future<void> _check(
  String name,
  WatermarkSettings s,
  int w,
  int h, {
  bool expectFull = false,
}) async {
  final full = await WatermarkRenderer.renderOverlayRaw(s, w, h);
  final part = await WatermarkRenderer.renderPart(
    s,
    w,
    h,
    ui.ImageByteFormat.rawRgba,
  );
  expect(part, isNotNull, reason: '$name：應該有東西可畫');
  final p = part!;
  expect(p.fullCanvas, expectFull, reason: '$name：整版/包圍盒判定');
  expect(p.bytes.length, p.width * p.height * 4);
  final l = p.box.left.toInt(), t = p.box.top.toInt();
  var maxDiff = 0;
  var outside = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final inBox = x >= l && x < l + p.width && y >= t && y < t + p.height;
      if (!inBox) {
        if (full[i + 3] != 0) outside++;
        continue;
      }
      final j = ((y - t) * p.width + (x - l)) * 4;
      for (var k = 0; k < 4; k++) {
        final d = (full[i + k] - p.bytes[j + k]).abs();
        if (d > maxDiff) maxDiff = d;
      }
    }
  }
  expect(outside, 0, reason: '$name：包圍盒外還有 $outside 個非透明像素（框算小了）');
  expect(maxDiff, lessThanOrEqualTo(2), reason: '$name：包圍盒內像素跟整版不同');
  debugPrint(
    '$name：包圍盒 ${p.width}x${p.height} 於 ${w}x$h'
    '（${(p.width * p.height * 100 / (w * h)).toStringAsFixed(1)}% 面積）'
    '，raw ${(p.bytes.length / 1024).round()}KB',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 真的思源黑體：量出來的位元組數才有參考價值（測試預設字型是方塊）
    final data = File('assets/fonts/NotoSansTC.ttf').readAsBytesSync();
    final loader = FontLoader('NotoSansTC')
      ..addFont(Future.value(ByteData.view(data.buffer)));
    await loader.load();
  });

  test('預設文字（置中、陰影、加粗）', () async {
    final s = WatermarkSettings(text: TextMark());
    await _check('預設文字 720', s, 1280, 720);
    await _check('預設文字 540', s, 960, 540);
  });

  test('角落文字＋描邊＋底色＋旋轉，部分在畫布外', () async {
    final s = WatermarkSettings(
      text: TextMark(
        text: '@corner_mark',
        x: 0.93,
        y: 0.9,
        sizeFrac: 0.09,
        rotation: 30,
        outline: true,
        outlineWidth: 0.15,
        bg: true,
        bgPad: 2.5,
        bgCorner: 0.8,
      ),
    );
    await _check('角落文字', s, 1280, 720);
  });

  test('模糊陰影＋最粗＋負字距＋大角度', () async {
    final s = WatermarkSettings(
      text: TextMark(
        text: '浮水印 Watermark',
        x: 0.4,
        y: 0.55,
        sizeFrac: 0.1,
        rotation: -75,
        shadowBlur: 0.2,
        shadowOpacity: 1,
        weight: 1,
        spacing: -0.2,
        opacity: 0.6,
      ),
    );
    await _check('模糊陰影', s, 720, 1280);
  });

  test('非正方形 Logo＋圓角＋旋轉', () async {
    final s = WatermarkSettings();
    s.text.enabled = false;
    s.logo
      ..enabled = true
      ..bytesValue = await _solidPng(const ui.Color(0xFFFF4020), 100, 60)
      ..opacity = 0.8
      ..sizeFrac = 0.3
      ..corner = 0.5
      ..rotation = 45
      ..x = 0.2
      ..y = 0.3;
    await _check('Logo', s, 1280, 720);
  });

  test('多文字：一張圖包住全部', () async {
    final s = WatermarkSettings(text: TextMark(text: 'A', x: 0.2, y: 0.2));
    s.addText()
      ..text = 'B'
      ..x = 0.8
      ..y = 0.8;
    await _check('多文字', s, 1280, 720);
  });

  test('整個在畫布外＝沒東西可畫', () async {
    final s = WatermarkSettings(text: TextMark(text: 'gone', x: 1.6, y: 0.5));
    final part = await WatermarkRenderer.renderPart(
      s,
      1280,
      720,
      ui.ImageByteFormat.rawRgba,
    );
    expect(part, isNull);
    final full = await WatermarkRenderer.renderOverlayRaw(s, 1280, 720);
    for (var i = 3; i < full.length; i += 4) {
      expect(full[i], 0, reason: '整版也應該是全透明');
    }
  });

  test('滿版平鋪退回整版', () async {
    final s = WatermarkSettings(
      text: TextMark(text: 'tile', sizeFrac: 0.05, tiled: true, rotation: 20),
    );
    await _check('平鋪', s, 640, 360, expectFull: true);
    final part = await WatermarkRenderer.renderPart(
      s,
      640,
      360,
      ui.ImageByteFormat.rawRgba,
    );
    expect(part!.fraction, [0, 0, 1, 1]);
  });

  test('一版的位元組數（S1 驗收：典型文字 < 300KB）', () async {
    final s = WatermarkSettings(text: TextMark());
    Future<int> rawAt(int w, int h) async => (await WatermarkRenderer.renderPart(
      s,
      w,
      h,
      ui.ImageByteFormat.rawRgba,
    ))!.bytes.length;
    final raw720 = await rawAt(1280, 720);
    final raw540 = await rawAt(960, 540);
    final png = (await WatermarkRenderer.renderPart(
      s,
      1920,
      1080,
      ui.ImageByteFormat.png,
    ))!;
    final fullRaw540 = 960 * 540 * 4;
    final fullPng1080 = (await WatermarkRenderer.renderOverlayPng(
      s,
      1920,
      1080,
    )).length;
    debugPrint(
      '預設文字一版：快路 raw 720＝${raw720 ~/ 1024}KB、540＝${raw540 ~/ 1024}KB'
      '（以前整版 540 raw＝${fullRaw540 ~/ 1024}KB）；'
      '全解析 PNG 1080＝${png.bytes.length ~/ 1024}KB'
      '（${png.width}x${png.height}，以前整版＝${fullPng1080 ~/ 1024}KB）',
    );
    // 編輯器的快路規則：文字 720，超過 300KB 預算退回 540
    final fastPick = raw720 <= 300 << 10 ? raw720 : raw540;
    expect(fastPick, lessThan(300 << 10), reason: '快路一版超過 300KB');
    expect(png.bytes.length, lessThan(300 << 10), reason: '全解析一版超過 300KB');
    expect(raw540, lessThan(fullRaw540 ~/ 4), reason: '包圍盒沒有比整版省 4 倍以上');
  });
}
