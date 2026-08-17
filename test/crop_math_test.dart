// 影片裁切的換算：框 ↔ 片段的縮放位移。
//
// 這組數學決定「裁完畫面對不對」，而且預覽、合成播放器、兩條匯出管線
// 都靠同一組 scale/px/py，錯了四邊一起錯。
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/crop_math.dart';

void main() {
  group('影片裁切的換算', () {
    test('整張都要＝不縮不移', () {
      for (final (srcAspect, canvasAspect) in const [
        (16 / 9, 16 / 9), // 一樣
        (9 / 16, 16 / 9), // 直的素材、橫的畫布
        (16 / 9, 9 / 16), // 反過來
        (4 / 3, 1.0),
      ]) {
        final t = cropToTransform(
          const Rect.fromLTWH(0, 0, 1, 1),
          srcAspect,
          canvasAspect,
        );
        // 素材貼合畫布之後，短邊那側本來就填不滿——要填滿整個畫布
        // 就得放大，這時 scale 會大於 1，那是對的
        final (fw, fh) = fitInCanvas(srcAspect, canvasAspect);
        final want = math.max(canvasAspect / fw, 1 / fh);
        expect(t.scale, closeTo(want, 1e-9));
        expect(t.px, closeTo(0.5, 1e-9));
        expect(t.py, closeTo(0.5, 1e-9));
      }
    });

    test('框越小放得越大', () {
      const src = 16 / 9;
      final full = cropToTransform(
        const Rect.fromLTWH(0, 0, 1, 1),
        src,
        src,
      );
      final half = cropToTransform(
        const Rect.fromLTWH(0.25, 0.25, 0.5, 0.5),
        src,
        src,
      );
      expect(half.scale, greaterThan(full.scale));
      expect(half.scale, closeTo(full.scale * 2, 1e-9));
      // 框在正中央：位置不該偏掉
      expect(half.px, closeTo(0.5, 1e-9));
      expect(half.py, closeTo(0.5, 1e-9));
    });

    test('框偏左上，畫面就要往右下推', () {
      const src = 16 / 9;
      final t = cropToTransform(
        const Rect.fromLTWH(0, 0, 0.5, 0.5),
        src,
        src,
      );
      expect(t.px, greaterThan(0.5));
      expect(t.py, greaterThan(0.5));
    });

    test('換算回去再換算過來，框不會跑掉', () {
      final r = math.Random(7);
      for (var i = 0; i < 2000; i++) {
        final srcAspect = [16 / 9, 9 / 16, 4 / 3, 1.0][r.nextInt(4)];
        final canvasAspect = [16 / 9, 9 / 16, 1.0][r.nextInt(3)];
        final w = 0.15 + r.nextDouble() * 0.85;
        final h = 0.15 + r.nextDouble() * 0.85;
        final x = r.nextDouble() * (1 - w);
        final y = r.nextDouble() * (1 - h);
        final crop = Rect.fromLTWH(x, y, w, h);
        final t = cropToTransform(crop, srcAspect, canvasAspect);
        final back = transformToCrop(
          t.scale,
          t.px,
          t.py,
          srcAspect,
          canvasAspect,
        );
        // 框的比例跟畫布不一樣時，短邊那側會被畫布切掉一點——
        // 所以只保證「回來的框」被原框包住、而且至少有一邊完全吻合
        expect(back.width, lessThanOrEqualTo(w + 1e-6));
        expect(back.height, lessThanOrEqualTo(h + 1e-6));
        final sameW = (back.width - w).abs() < 1e-6;
        final sameH = (back.height - h).abs() < 1e-6;
        expect(
          sameW || sameH,
          isTrue,
          reason: '兩邊都被切掉了：$crop → $back',
        );
        expect(back.center.dx, closeTo(crop.center.dx, 1e-6));
        expect(back.center.dy, closeTo(crop.center.dy, 1e-6));
      }
    });

    test('再怎麼亂都不會產生 NaN 或負的縮放', () {
      final r = math.Random(11);
      for (var i = 0; i < 5000; i++) {
        final t = cropToTransform(
          Rect.fromLTWH(
            r.nextDouble() - 0.5,
            r.nextDouble() - 0.5,
            r.nextDouble() * 2,
            r.nextDouble() * 2,
          ),
          0.05 + r.nextDouble() * 8,
          0.05 + r.nextDouble() * 8,
        );
        expect(t.scale.isFinite && t.scale > 0, isTrue);
        expect(t.px.isFinite && t.py.isFinite, isTrue);
      }
    });
  });
}
