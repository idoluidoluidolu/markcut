// GIF 頁的起訖點規矩。
//
// 把手不吃觸控之後（使用者指定：拉桿改成無法靠觸控拖曳，頭尾一律靠
// 自己按起點終點），起訖點只剩「指針停在哪，按鈕就設在哪」一個入口，
// 而指針又可以自由跑到選取範圍外面。使用者接著指定：起點設在終點
// 之後「不要擋，自動把長度橫移過去，終點自動改後面就好」——所以按下
// 去永遠算數，這裡釘住「範圍變成什麼」：
//   1. 指針在正確側：只動這一端
//   2. 指針跑到另一端上或另一側：整段平移、長度不變
//   3. 頂到影片頭尾：長度才縮，但不低於最短長度；永遠不會生出負範圍
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/gif_trim_range.dart';

void main() {
  group('設起點', () {
    test('指針在終點左邊：只動起點，終點不動', () {
      expect(trimSetStart(3.0, 1.0, 10.0, 30.0), (start: 3.0, end: 10.0));
      expect(trimSetStart(0.0, 1.0, 10.0, 30.0), (start: 0.0, end: 10.0));
    });

    test('剛好留下最短長度：只動起點', () {
      final r = trimSetStart(10.0 - kTrimMinGap, 1.0, 10.0, 30.0);
      expect(r.start, closeTo(9.8, 1e-9));
      expect(r.end, 10.0);
    });

    test('指針太靠近終點（範圍會短於最短長度）：整段平移，長度不變', () {
      // 原本 1~10（長 9），起點設到 9.9 → 9.9~18.9
      final r = trimSetStart(9.9, 1.0, 10.0, 30.0);
      expect(r.start, closeTo(9.9, 1e-9));
      expect(r.end, closeTo(18.9, 1e-9));
    });

    test('指針跑到終點右邊：整段平移過去，終點跟著往後', () {
      // 原本 1~10（長 9），起點設到 20 → 20~29
      expect(trimSetStart(20.0, 1.0, 10.0, 30.0), (start: 20.0, end: 29.0));
      // 剛好在終點上也一樣
      expect(trimSetStart(10.0, 1.0, 10.0, 30.0), (start: 10.0, end: 19.0));
    });

    test('平移後尾端頂到影片結尾：終點停在結尾、長度縮短', () {
      // 原本 1~10（長 9），起點設到 25 → 25~30
      expect(trimSetStart(25.0, 1.0, 10.0, 30.0), (start: 25.0, end: 30.0));
    });

    test('起點最遠只到「還留得下最短長度」的地方', () {
      final r = trimSetStart(29.95, 1.0, 10.0, 30.0);
      expect(r.start, closeTo(30.0 - kTrimMinGap, 1e-9));
      expect(r.end, 30.0);
    });

    test('負數收在 0', () {
      expect(trimSetStart(-1.0, 1.0, 10.0, 30.0), (start: 0.0, end: 10.0));
    });
  });

  group('設終點', () {
    test('指針在起點右邊：只動終點，起點不動', () {
      expect(trimSetEnd(25.0, 10.0, 20.0, 30.0), (start: 10.0, end: 25.0));
    });

    test('剛好留下最短長度：只動終點', () {
      final r = trimSetEnd(10.0 + kTrimMinGap, 10.0, 20.0, 30.0);
      expect(r.start, 10.0);
      expect(r.end, closeTo(10.2, 1e-9));
    });

    test('指針太靠近起點：整段往前平移，長度不變', () {
      // 原本 10~20（長 10），終點設到 10.1 → 0.1~10.1
      final r = trimSetEnd(10.1, 10.0, 20.0, 30.0);
      expect(r.start, closeTo(0.1, 1e-9));
      expect(r.end, closeTo(10.1, 1e-9));
    });

    test('指針跑到起點左邊：整段往前平移，起點跟著往前', () {
      // 原本 20~25（長 5），終點設到 12 → 7~12
      expect(trimSetEnd(12.0, 20.0, 25.0, 30.0), (start: 7.0, end: 12.0));
      // 剛好在起點上也一樣
      expect(trimSetEnd(20.0, 20.0, 25.0, 30.0), (start: 15.0, end: 20.0));
    });

    test('平移後頭端頂到 0：起點停在 0、長度縮短', () {
      // 原本 10~20（長 10），終點設到 4 → 0~4
      expect(trimSetEnd(4.0, 10.0, 20.0, 30.0), (start: 0.0, end: 4.0));
    });

    test('不會超過總長', () {
      expect(trimSetEnd(31.0, 10.0, 20.0, 30.0), (start: 10.0, end: 30.0));
    });

    test('終點最近只到「還留得下最短長度」的地方', () {
      final r = trimSetEnd(0.05, 10.0, 20.0, 30.0);
      expect(r.end, closeTo(kTrimMinGap, 1e-9));
      expect(r.start, 0.0);
    });
  });

  group('不變量', () {
    test('任何輸入之後 0 ≤ start < end ≤ dur，長度 ≥ 最短長度（影片夠長時）', () {
      const dur = 30.0;
      for (var s = 0.0; s <= dur; s += 1.7) {
        for (var e = s + 0.3; e <= dur; e += 2.3) {
          for (var t = -2.0; t <= dur + 2; t += 0.9) {
            for (final r in [
              trimSetStart(t, s, e, dur),
              trimSetEnd(t, s, e, dur),
            ]) {
              expect(r.start, greaterThanOrEqualTo(0.0));
              expect(r.end, lessThanOrEqualTo(dur));
              expect(
                r.end - r.start,
                greaterThanOrEqualTo(kTrimMinGap - 1e-9),
                reason: 's=$s e=$e t=$t → $r',
              );
            }
          }
        }
      }
    });

    test('影片比最短長度還短：不會生出負範圍', () {
      final a = trimSetStart(0.0, 0.0, 0.1, 0.1);
      expect(a.start, 0.0);
      expect(a.end, 0.1);
      final b = trimSetEnd(0.1, 0.0, 0.1, 0.1);
      expect(b.start, 0.0);
      expect(b.end, 0.1);
    });
  });
}
