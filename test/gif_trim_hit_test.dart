// GIF 頁修剪條的命中判定（使用者回報：把手拉到 0.2 秒之後再也拉不開）
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/gif_trim_hit.dart';

void main() {
  // 30 秒影片、修剪條 343pt：0.2 秒 ≈ 2.3pt，兩根把手幾乎完全重疊
  const w = 343.0;
  const dur = 30.0;
  double xOf(double t) => w * t / dur;

  group('把手貼在一起（0.2 秒）', () {
    final xs = xOf(10.0);
    final xe = xOf(10.2);
    TrimTarget pick(double x, {double? xp}) =>
        TrimHit.pick(x: x, xs: xs, xe: xe, xp: xp);

    test('落在把手上分不出來，看方向：往左動起點、往右動終點', () {
      expect(pick(xs + 1, xp: xs), TrimTarget.either);
      expect(pick(xs, xp: xs), TrimTarget.either);
      expect(pick(xs + 5, xp: xs), TrimTarget.either);
      expect(TrimHit.byDirection(-2), TrimTarget.start);
      expect(TrimHit.byDirection(2), TrimTarget.end);
      expect(TrimHit.byDirection(0), TrimTarget.either);
    });

    test('落在左邊外側一定是起點、右邊外側一定是終點', () {
      expect(pick(xs - 20, xp: xs), TrimTarget.start);
      expect(pick(xs - 15, xp: xs), TrimTarget.start);
      expect(pick(xe + 20, xp: xs), TrimTarget.end);
      expect(pick(xe + 15, xp: xs), TrimTarget.end);
    });

    test('播放頭停在起點上也搶不走把手', () {
      for (final x in [xs - 15, xs, xs + 5, xe + 15]) {
        expect(pick(x, xp: xs), isNot(TrimTarget.playhead));
      }
    });

    test('離熱區夠遠才是空白處／播放頭', () {
      expect(pick(xs - 40, xp: xs), TrimTarget.background);
      expect(pick(xs - 40, xp: xs - 40), TrimTarget.playhead);
      expect(pick(xe + 40, xp: null), TrimTarget.background);
    });
  });

  group('把手很近但直條沒疊到（約 3.5 秒＝40pt）', () {
    final xs = xOf(10.0);
    final xe = xs + 40;
    TrimTarget pick(double x) => TrimHit.pick(x: x, xs: xs, xe: xe, xp: xs);

    test('按在直條上就是那根（按起點往右拉＝從左邊縮）', () {
      expect(pick(xs + 6), TrimTarget.start);
      expect(pick(xe - 6), TrimTarget.end);
    });

    test('兩根直條中間看方向、外側各歸各的', () {
      expect(pick((xs + xe) / 2), TrimTarget.either);
      expect(pick(xs - 10), TrimTarget.start);
      expect(pick(xe + 10), TrimTarget.end);
    });
  });

  group('把手離得夠遠', () {
    final xs = xOf(5.0);
    final xe = xOf(20.0);
    TrimTarget pick(double x, {double? xp}) =>
        TrimHit.pick(x: x, xs: xs, xe: xe, xp: xp);

    test('直條本身', () {
      expect(pick(xs + 6), TrimTarget.start);
      expect(pick(xe - 6), TrimTarget.end);
    });

    test('播放頭停在起點把手上：按直條拉把手、按播放頭左側拉播放頭', () {
      expect(pick(xs + 6, xp: xs), TrimTarget.start);
      expect(pick(xs - 5, xp: xs), TrimTarget.start); // 核心內
      expect(pick(xs - 15, xp: xs), TrimTarget.playhead);
    });

    test('中間空白：點哪跳哪；播放頭在中間可拖', () {
      final mid = (xs + xe) / 2;
      expect(pick(mid), TrimTarget.background);
      expect(pick(mid + 10, xp: mid), TrimTarget.playhead);
      expect(pick(mid + 30, xp: mid), TrimTarget.background);
    });

    test('熱區外圍（核心以外、播放頭不在）仍算把手', () {
      expect(pick(xs - 28), TrimTarget.start);
      expect(pick(xe + 28), TrimTarget.end);
      expect(pick(xs - 33), TrimTarget.background);
    });
  });

  group('最短長度只擋往內', () {
    test('起點往外自由', () => expect(clampTrimStart(3.0, 10.2), 3.0));
    test('起點往內夾在終點前 0.2', () {
      expect(clampTrimStart(10.15, 10.2), closeTo(10.0, 1e-9));
    });
    test('終點往外自由', () => expect(clampTrimEnd(25.0, 10.0, 30.0), 25.0));
    test('終點往內夾在起點後 0.2、不超過總長', () {
      expect(clampTrimEnd(10.05, 10.0, 30.0), closeTo(10.2, 1e-9));
      expect(clampTrimEnd(31.0, 10.0, 30.0), 30.0);
    });
    test('影片比最短長度還短也不會出現負值', () {
      expect(clampTrimStart(0.0, 0.1), 0.0);
      expect(clampTrimStart(-1.0, 0.1), 0.0);
      expect(clampTrimEnd(0.1, 0.0, 0.1), 0.1);
    });
  });
}
