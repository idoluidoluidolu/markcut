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
        // 整張框起來＝維持原樣（scale 正好 1）。以前是「填滿畫布」，
        // 直式影片放橫式畫布時會憑空被放大一刀
        expect(t.scale, closeTo(1, 1e-9));
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
        // 框的比例跟畫布不一樣時，另一側會看到比框更多的畫面——
        // 所以是「回來的框包住原框」，而且至少有一邊完全吻合
        expect(back.width, greaterThanOrEqualTo(w - 1e-6));
        expect(back.height, greaterThanOrEqualTo(h - 1e-6));
        final sameW = (back.width - w).abs() < 1e-6;
        final sameH = (back.height - h).abs() < 1e-6;
        expect(
          sameW || sameH,
          isTrue,
          reason: '兩邊都跑掉了：$crop → $back',
        );
        // 重新打開裁切時看到的框，要把上次框的範圍整個包住
        //（另一側會多看到一點畫面，那正是「不補滿」的結果）
        expect(back.left, lessThanOrEqualTo(crop.left + 1e-6));
        expect(back.right, greaterThanOrEqualTo(crop.right - 1e-6));
        expect(back.top, lessThanOrEqualTo(crop.top + 1e-6));
        expect(back.bottom, greaterThanOrEqualTo(crop.bottom - 1e-6));
      }
    });

    test('鏡像的框翻兩次回到原樣，翻一次左右互換', () {
      final r = math.Random(3);
      for (var i = 0; i < 2000; i++) {
        final w = 0.05 + r.nextDouble() * 0.9;
        final x = r.nextDouble() * (1 - w);
        final rect = Rect.fromLTWH(x, r.nextDouble() * 0.5, w, 0.3);
        final f = flipRectX(rect);
        // 左緣到左邊的距離＝原本右緣到右邊的距離
        expect(f.left, closeTo(1 - rect.right, 1e-12));
        expect(f.width, closeTo(rect.width, 1e-12));
        expect(f.top, rect.top);
        final back = flipRectX(f);
        expect(back.left, closeTo(rect.left, 1e-12));
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
