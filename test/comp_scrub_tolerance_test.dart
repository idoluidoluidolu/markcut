// 合成播放器拖動時的 seek 容忍值（見 compScrubToleranceMs）：原檔 500
//（關鍵幀貼齊，往回滑不用重解）、代理 250（≥1 個 GOP，而且是原生拖曳
// 快取的收件窗）、放手一律 0
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/scrub_frame_queue.dart';

void main() {
  test('原檔拖動：500ms＝±0.5 秒的窗，蓋得住最疏 30 格的 GOP', () {
    expect(compScrubToleranceMs(exact: false, raw: true), 500);
  });

  test('代理（密關鍵幀）拖動：250ms，不是 0——這個數也是快取的收件窗', () {
    expect(compScrubToleranceMs(exact: false, raw: false), 250);
    expect(kCompScrubDenseToleranceMs, 250);
  });

  // 給 0 就是快取形同關閉（收件窗只剩 1ms），每一格都要重新解碼＋重跑
  // 一次 CI 合成——實測 199：代理落地後 26 秒滑動 312 發 seek 產生 310 格
  // CI 重畫、命中掛零，轉向那一格就卡（往左滑、往左再往右）
  test('拖動中兩種來源都要有窗，不能是 0', () {
    for (final raw in [true, false]) {
      expect(compScrubToleranceMs(exact: false, raw: raw), greaterThan(0));
    }
  });

  // 代理的 GOP 是 5 格＝167ms：窗要 ≥1 個 GOP，往前往回都保證找得到
  // 關鍵幀，不必從前一個關鍵幀一路重解
  test('代理的窗蓋得住它自己的 GOP（5 格 @30fps＝167ms）', () {
    expect(
      compScrubToleranceMs(exact: false, raw: false),
      greaterThanOrEqualTo((5 / 30 * 1000).ceil()),
    );
    // 但不必給到原檔那麼寬：拖動中畫面最多差這麼多
    expect(
      compScrubToleranceMs(exact: false, raw: false),
      lessThan(kCompScrubToleranceCapMs),
    );
  });

  test('放手的精準發：不管原檔還是代理都是 0', () {
    expect(compScrubToleranceMs(exact: true, raw: true), 0);
    expect(compScrubToleranceMs(exact: true, raw: false), 0);
  });

  test('Dart 端的上限跟原生端同一個數（500）', () {
    expect(kCompScrubToleranceCapMs, 500);
  });

  test('不超過原生端的上限 500（AppDelegate tolerance(exact:milliseconds:)）', () {
    for (final raw in [true, false]) {
      for (final exact in [true, false]) {
        expect(
          compScrubToleranceMs(exact: exact, raw: raw),
          inInclusiveRange(0, 500),
        );
      }
    }
  });
}
