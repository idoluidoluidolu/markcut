// 浮水印 PNG 的陰影體檢：renderOverlayPng 出來的圖，字的右下方
// 應該要有「暗的半透明像素」（陰影）。實測回報「預覽有浮雕感、
// 匯出扁平」——這支測試把問題切成兩半：PNG 本身就沒陰影（渲染器
// 的鍋）還是合成時弄丟（CA/CI 的鍋）
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/watermark_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('renderOverlayPng 的文字帶陰影（暗色半透明像素存在）', () async {
    final s = WatermarkSettings(
      text: TextMark(text: '@我的浮水印'), // 預設樣式：白字、陰影開
    );
    final png = await WatermarkRenderer.renderOverlayPng(s, 540, 960);
    final codec = await ui.instantiateImageCodec(png);
    final img = (await codec.getNextFrame()).image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);
    final bytes = data!.buffer.asUint8List();

    var bright = 0; // 白字本體
    var dark = 0; // 陰影（暗色、半透明）
    for (var i = 0; i < bytes.length; i += 4) {
      final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2], a = bytes[i + 3];
      if (a < 10) continue;
      final lum = (r + g + b) / 3;
      // rawRgba 是預乘 alpha：白字 55% 預乘後 lum≈a≈140
      if (lum > 100 && lum >= a - 30) bright++;
      if (lum < 80) dark++;
    }
    // 有字
    expect(bright, greaterThan(200), reason: '白字本體不見了');
    // 有陰影：暗像素至少要有白字像素的一成（陰影是一圈模糊暈，
    // 面積不會小）
    expect(
      dark,
      greaterThan(bright ~/ 10),
      reason: '陰影不見了：PNG 裡幾乎沒有暗色半透明像素（浮雕感在渲染端就丟了）',
    );
    img.dispose();
  });
}
