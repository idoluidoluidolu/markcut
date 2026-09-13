import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/overlay_geometry.dart';

void main() {
  test('圖片位置、大小、旋轉、透明度不改點陣指紋', () {
    final s = WatermarkSettings();
    s.logo
      ..enabled = true
      ..bytesValue = Uint8List.fromList([1, 2, 3]);
    final raster = watermarkVisualSignature(s, rasterOnly: true);
    final visual = watermarkVisualSignature(s);
    s.logo
      ..x = 0.2
      ..y = 0.3
      ..sizeFrac = 0.7
      ..rotation = 45
      ..opacity = 0.4;
    expect(watermarkVisualSignature(s, rasterOnly: true), raster);
    expect(watermarkVisualSignature(s), isNot(visual));
    final item = watermarkGeometryItems(s, 'g').first;
    expect(item['x'], 0.2);
    expect(item['scale'], 0.7);
    expect(item['opacity'], 0.4);
    s.logo.corner = 0.2;
    expect(watermarkVisualSignature(s, rasterOnly: true), isNot(raster));
  });

  test('隱藏保留所有部件 ID 並即時歸零透明度', () {
    final s = WatermarkSettings();
    s.logo
      ..enabled = true
      ..bytesValue = Uint8List.fromList([1]);
    s.text
      ..enabled = true
      ..text = 'test';
    final shown = watermarkGeometryItems(s, 'g');
    final hidden = watermarkGeometryItems(s, 'g', visible: false);
    expect(hidden.map((i) => i['id']), shown.map((i) => i['id']));
    expect(hidden.every((i) => i['opacity'] == 0), isTrue);
  });

  test('平鋪與位移动畫仍走點陣更新', () {
    expect(overlayCanTransform(true, WmAnimation.none), isFalse);
    expect(overlayCanTransform(false, WmAnimation.drift), isFalse);
    expect(overlayCanTransform(false, WmAnimation.marquee), isFalse);
    expect(overlayCanTransform(false, WmAnimation.blink), isTrue);
  });
}
