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
      // 透明度固定 0.55：下面的門檻是照它校的（預設值後來調成 0.7，
      // 這支測的是渲染行為，不是預設值）。模糊開一點：這支要抓的
      // 是「柔邊暈」有沒有活著走出渲染器（硬影只有右下一條細邊，
      // 面積門檻對它沒意義）
      text: TextMark(text: '@我的浮水印', opacity: 0.55, shadowBlur: 0.08),
    );
    final png = await WatermarkRenderer.renderOverlayPng(s, 540, 960);
    final codec = await ui.instantiateImageCodec(png);
    final img = (await codec.getNextFrame()).image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data, isNotNull);
    final bytes = data!.buffer.asUint8List();

    var bright = 0; // 白字本體
    var dark = 0; // 陰影（暗色、半透明）
    var muddy = 0; // 字肚被自己的陰影染灰（透明度沒作用在整組上）
    for (var i = 0; i < bytes.length; i += 4) {
      final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2], a = bytes[i + 3];
      if (a < 10) continue;
      final lum = (r + g + b) / 3;
      // rawRgba 是預乘 alpha：白字 55% 預乘後 lum≈a≈140
      if (lum > 100 && lum >= a - 30) bright++;
      if (lum < 80) dark++;
      // 半透明白字壓在黑影上（舊畫法）：lum 140 但 a 175——
      // 亮度追不上 alpha 就是字肚透出了底下的影子
      if (a >= 100 && lum >= 80 && lum < a - 30) muddy++;
    }
    // 有字
    expect(bright, greaterThan(200), reason: '白字本體不見了');
    // 字肚乾淨：透明度作用在「整組」，陰影不能透進半透明的字裡
    expect(
      muddy,
      lessThan(bright ~/ 10),
      reason: '字肚被自己的陰影染灰（透明度沒有整組一起套）',
    );
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
