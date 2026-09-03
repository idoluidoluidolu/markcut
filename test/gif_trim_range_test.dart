// GIF 頁的起訖點規矩。
//
// 把手不吃觸控之後（使用者指定：拉桿改成無法靠觸控拖曳，頭尾一律靠
// 自己按起點終點），起訖點只剩「指針停在哪，按鈕就設在哪」一個入口，
// 而指針又可以自由跑到選取範圍外面——所以「按下去這一下算不算數」
// 從冷門的邊界變成天天會遇到的事，這裡把它釘住
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/gif_trim_range.dart';

void main() {
  group('設起點', () {
    test('指針在終點左邊：照指針的位置設', () {
      expect(trimStartAt(3.0, 10.0), 3.0);
      expect(trimStartAt(0.0, 10.0), 0.0);
    });

    test('剛好留下最短長度：算數', () {
      expect(trimStartAt(10.0 - kTrimMinGap, 10.0), closeTo(9.8, 1e-9));
    });

    test('指針太靠近終點（範圍會短於最短長度）：不算數，不偷偷夾', () {
      expect(trimStartAt(9.9, 10.0), isNull);
    });

    test('指針跑到終點右邊：不算數（指針現在本來就可以在範圍外）', () {
      expect(trimStartAt(20.0, 10.0), isNull);
      expect(trimStartAt(10.0, 10.0), isNull);
    });

    test('負數收在 0', () => expect(trimStartAt(-1.0, 10.0), 0.0));
  });

  group('設終點', () {
    test('指針在起點右邊：照指針的位置設', () {
      expect(trimEndAt(25.0, 10.0, 30.0), 25.0);
    });

    test('剛好留下最短長度：算數', () {
      expect(trimEndAt(10.0 + kTrimMinGap, 10.0, 30.0), closeTo(10.2, 1e-9));
    });

    test('指針太靠近起點：不算數', () {
      expect(trimEndAt(10.1, 10.0, 30.0), isNull);
    });

    test('指針跑到起點左邊：不算數', () {
      expect(trimEndAt(2.0, 10.0, 30.0), isNull);
      expect(trimEndAt(10.0, 10.0, 30.0), isNull);
    });

    test('不會超過總長', () => expect(trimEndAt(31.0, 10.0, 30.0), 30.0));
  });

  test('影片比最短長度還短：兩顆鈕都按不動，不會生出負範圍', () {
    expect(trimStartAt(0.0, 0.1), isNull);
    expect(trimEndAt(0.1, 0.0, 0.1), isNull);
  });
}
