// 照片去色（decontaminateRgba，同 FFmpeg cutoutDecontFilter／iOS MCCutoutDecont）：
//   1. 人裡面（α=255）跟外面（α=0）一個位元都不動、整張沒有半透明就原樣
//   2. 交界那一圈：左半紅色的人、右半白色的舊背景，遮罩在交界右邊漸到 0——
//      換到藍背景上綠色要比照舊合成低（不再是白邊）
//   3. 縮圖算估計＋原尺寸套公式：跟整張原尺寸算差不多
//   4. 高斯近似：常數不變、總和不變
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/cutout_decont.dart';

(Uint8List, Uint8List) _scene(int w, int h) {
  final rgba = Uint8List(w * h * 4);
  final alpha = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = y * w + x;
      final red = x < w ~/ 2;
      rgba[p * 4] = red ? 200 : 255;
      rgba[p * 4 + 1] = red ? 40 : 255;
      rgba[p * 4 + 2] = red ? 40 : 255;
      rgba[p * 4 + 3] = 255;
      final e = w ~/ 2;
      alpha[p] = x < e
          ? 255
          : (x >= e + 8 ? 0 : (255 * (1 - (x - e + 1) / 9)).round());
    }
  }
  return (rgba, alpha);
}

void main() {
  test('沒有半透明：原樣（alpha 補成不透明）', () {
    final rgba = Uint8List.fromList(List.generate(4 * 4 * 4, (i) => i * 3 % 256));
    final alpha = Uint8List.fromList(List.generate(16, (i) => i < 8 ? 255 : 0));
    final out = decontaminateRgba(rgba, alpha, 4, 4);
    for (var p = 0; p < 16; p++) {
      for (var c = 0; c < 3; c++) {
        expect(out[p * 4 + c], rgba[p * 4 + c]);
      }
      expect(out[p * 4 + 3], 255);
    }
  });

  test('交界那一圈不再是白邊，人裡面、外面不動', () {
    const w = 320, h = 32;
    final (rgba, alpha) = _scene(w, h);
    final out = decontaminateRgba(rgba, alpha, w, h);
    const row = 16;
    int at(int x, int c) => out[(row * w + x) * 4 + c];
    expect(at(40, 0), 200);
    expect(at(40, 1), 40);
    expect(at(300, 1), 255, reason: '外面（α=0）照抄');
    for (var x = 161; x <= 165; x++) {
      final a = alpha[row * w + x] / 255;
      // 合成到藍背景（G=120）：照舊 vs 去色後
      final plainG = a * 255 + (1 - a) * 120;
      final g = a * at(x, 1) + (1 - a) * 120;
      expect(
        g,
        lessThan(plainG - 15),
        reason: 'x=$x α=${a.toStringAsFixed(2)} 照舊 $plainG 去色後 $g',
      );
    }
  });

  test('縮圖算估計跟原尺寸算差不多（最後一步在原尺寸）', () {
    const w = 640, h = 64;
    final (rgba, alpha) = _scene(w, h);
    final full = decontaminateRgba(rgba, alpha, w, h, workLong: 4096);
    final small = decontaminateRgba(rgba, alpha, w, h, workLong: 160);
    var worst = 0;
    for (var i = 0; i < full.length; i++) {
      final d = (full[i] - small[i]).abs();
      if (d > worst) worst = d;
    }
    expect(worst, lessThan(24));
  });

  test('高斯近似：常數不變、總和不變（邊界取最近像素）', () {
    final flat = Float32List.fromList(List.filled(50 * 30, 0.4));
    gaussBlurInPlace(flat, 50, 30, 1, 5);
    for (final v in flat) {
      expect(v, closeTo(0.4, 1e-5));
    }
    final dot = Float32List(101 * 101);
    dot[50 * 101 + 50] = 1;
    gaussBlurInPlace(dot, 101, 101, 1, 4);
    expect(dot.fold<double>(0, (s, v) => s + v), closeTo(1, 1e-3));
    expect(dot[50 * 101 + 50], lessThan(0.05));
  });
}
