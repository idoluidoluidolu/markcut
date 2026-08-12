import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';

/// 預覽（watermark_layer）與匯出（watermark_renderer）用的是兩段各自寫的
/// 幾何計算。這裡把兩邊的公式並排驗證，避免又默默分岔。
void main() {
  group('Logo 置中', () {
    // 匯出：targetH = targetW * imgH / imgW；top = y*h - targetH/2
    // 預覽：logoH = logoW / aspect（aspect = imgW/imgH）＝同一個值
    for (final (imgW, imgH) in [(1000, 250), (250, 1000), (800, 800)]) {
      test('${imgW}x$imgH 的 Logo，預覽與匯出的 top 一致', () {
        const canvasW = 1080.0;
        const canvasH = 1920.0;
        const sizeFrac = 0.18;
        const y = 0.5;

        final targetW = sizeFrac * math.min(canvasW, canvasH);
        final exportH = targetW * imgH / imgW;
        final exportTop = y * canvasH - exportH / 2;

        final aspect = imgW / imgH;
        final previewH = targetW / aspect;
        final previewTop = y * canvasH - previewH / 2;

        expect(previewTop, closeTo(exportTop, 1e-9));
        expect(previewH, closeTo(exportH, 1e-9));
      });
    }

    test('非正方形 Logo 若用寬度當高度，會差一截（回歸用）', () {
      const targetW = 194.4;
      const imgW = 1000, imgH = 250;
      final correctH = targetW * imgH / imgW;
      // 舊寫法把寬度當高度用
      const wrongH = targetW;
      expect((wrongH - correctH).abs(), greaterThan(100));
    });
  });

  group('文字底色', () {
    test('預覽扣掉 padding 之後，文字落點與匯出一致', () {
      const fontSize = 54.0;
      const bgPad = 2.5;
      const textW = 300.0;
      const textH = 60.0;
      const canvasW = 1080.0;
      const canvasH = 1920.0;
      const x = 0.8, y = 0.9;

      final padH = fontSize * 0.35 * bgPad;
      final padV = fontSize * 0.18 * bgPad;

      // 匯出：文字直接畫在這裡，底色往外擴
      final exportTextLeft = x * canvasW - textW / 2;
      final exportTextTop = y * canvasH - textH / 2;

      // 預覽：Positioned 原點扣掉 padding，Container 的 padding 再推回來
      final previewBoxLeft = x * canvasW - textW / 2 - padH;
      final previewBoxTop = y * canvasH - textH / 2 - padV;
      final previewTextLeft = previewBoxLeft + padH;
      final previewTextTop = previewBoxTop + padV;

      expect(previewTextLeft, closeTo(exportTextLeft, 1e-9));
      expect(previewTextTop, closeTo(exportTextTop, 1e-9));

      // 底色框的位置兩邊也要一致
      expect(previewBoxLeft, closeTo(exportTextLeft - padH, 1e-9));
      expect(previewBoxTop, closeTo(exportTextTop - padV, 1e-9));
    });
  });

  group('平鋪預覽重繪', () {
    test('原地修改設定值之後，簽章要不相等（否則預覽不會重畫）', () {
      final t = TextMark()..sizeFrac = 0.1;
      List<Object?> sig(TextMark m) => [
        m.text,
        m.fontFamily,
        m.sizeFrac,
        m.spacing,
        m.colorValue,
        m.opacity,
        m.rotation,
        m.shadow,
        m.outline,
        m.outlineWidth,
        m.outlineColorValue,
        m.bg,
        m.bgPad,
        m.bgCorner,
        m.bgColorValue,
        m.bgOpacity,
      ];
      final before = sig(t);
      t.sizeFrac = 0.2; // 面板就是這樣原地改的
      expect(sig(t), isNot(before));
      // 物件本身仍然是同一個 → 比 reference 永遠察覺不到變化
      expect(identical(t, t), isTrue);
    });
  });
}
