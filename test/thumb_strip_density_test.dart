// 縮圖帶的密度與「磚 → 格」對應（實測 199：指針位置的縮圖跟上方播放畫面
// 不同）。
//
// 以前每支影片固定 10 格：48 秒的片一格 4.8 秒，時間軸縮放到一磚 1.5 秒時
// 同一張圖連鋪六磚；而且磚畫的是「左緣那格」的整數近似，指針落在磚裡任何
// 位置都可能看到一磚寬以前的畫面。現在一秒一格、磚畫它中央那一刻的格。
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/timeline_strip.dart';

void main() {
  group('thumbStripCount', () {
    test('一秒一格、最少 10 格', () {
      expect(thumbStripCount(48.38), 49);
      expect(thumbStripCount(5.67), 10);
      expect(thumbStripCount(1.17), 10);
      expect(thumbStripCount(10.0), 10);
      expect(thumbStripCount(10.5), 11);
    });

    test('上限 $kThumbStripMax 格', () {
      expect(thumbStripCount(3600), kThumbStripMax);
    });

    test('壞輸入回 10', () {
      expect(thumbStripCount(0), 10);
      expect(thumbStripCount(-3), 10);
      expect(thumbStripCount(double.nan), 10);
      expect(thumbStripCount(double.infinity), 10);
    });
  });

  group('stripIndexForTile', () {
    // 199 的情境：48.38 秒整支、49 格、一磚 1.47 秒（磚寬 110px、75px/s）
    const dur = 48.38;
    const frames = 49;
    const tileSec = 110 / 75;
    double centerOf(int k) => (k + 0.5) * tileSec / dur;
    int at(int k) => stripIndexForTile(
      trimStart: 0,
      trimEnd: dur,
      duration: dur,
      frames: frames,
      centerFrac: centerOf(k),
    );

    test('磚畫它中央那一刻的格：每磚跟指針最多差半磚', () {
      // 磚 0 中央 0.73s → 格 0；磚 1 中央 2.2s → 格 2；磚 5 中央 8.07s → 格 8
      expect(at(0), 0);
      expect(at(1), 2);
      expect(at(5), 8);
      // 每一磚：格的時間窗（一秒）跟磚中央的距離都在半磚以內
      final tiles = (dur / tileSec).ceil();
      for (var k = 0; k < tiles; k++) {
        final center = (k + 0.5) * tileSec;
        final cell = at(k);
        expect(center, greaterThanOrEqualTo(cell * dur / frames - 1e-9));
        expect(center, lessThan((cell + 1) * dur / frames + 1e-9));
      }
    });

    test('以前的算法對照：10 格、左緣近似，磚 1 還在畫第 0 格（2.4 秒）', () {
      // 舊算式 i0 + k * span ~/ count（整支：i0 0、span 10、count 33）
      const count = 33;
      int old(int k) => (0 + (k * 10 ~/ count)).clamp(0, 9);
      expect(old(1), 0, reason: '磚 1（1.47～2.93s）畫的是 0～4.8s 那格');
      expect(old(5), 1, reason: '磚 5（7.3～8.8s）畫的是 4.8～9.6s 那格');
    });

    test('裁過的片段從 trimStart 起算', () {
      final i = stripIndexForTile(
        trimStart: 10,
        trimEnd: 20,
        duration: dur,
        frames: frames,
        centerFrac: 0.5,
      );
      expect(i, (15 / dur * frames).floor());
    });

    test('倒轉片段：來源時間從右往左', () {
      int rev(double f) => stripIndexForTile(
        trimStart: 10,
        trimEnd: 20,
        duration: dur,
        frames: frames,
        centerFrac: f,
        reverse: true,
      );
      expect(rev(0), (20 / dur * frames).floor());
      expect(rev(1), (10 / dur * frames).floor());
    });

    test('邊界夾住、壞輸入不會爆', () {
      expect(
        stripIndexForTile(
          trimStart: 0,
          trimEnd: dur,
          duration: dur,
          frames: frames,
          centerFrac: 1,
        ),
        frames - 1,
      );
      expect(
        stripIndexForTile(
          trimStart: 0,
          trimEnd: dur,
          duration: dur,
          frames: frames,
          centerFrac: -3,
        ),
        0,
      );
      expect(
        stripIndexForTile(
          trimStart: 0,
          trimEnd: dur,
          duration: dur,
          frames: frames,
          centerFrac: double.nan,
        ),
        0,
      );
      expect(
        stripIndexForTile(
          trimStart: 0,
          trimEnd: dur,
          duration: 0,
          frames: frames,
          centerFrac: 0.5,
        ),
        0,
      );
      expect(
        stripIndexForTile(
          trimStart: 0,
          trimEnd: dur,
          duration: dur,
          frames: 0,
          centerFrac: 0.5,
        ),
        0,
      );
    });
  });
}
