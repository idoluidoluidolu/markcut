// 合成播放器拖動時的 seek 容忍值（見 compScrubToleranceMs）：
// 原檔拖動給滿 500（關鍵幀貼齊，往回滑不用重解）、代理 0、放手一律 0
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/scrub_frame_queue.dart';

void main() {
  test('原檔拖動：500ms＝±0.5 秒的窗，蓋得住最疏 30 格的 GOP', () {
    expect(compScrubToleranceMs(exact: false, raw: true), 500);
  });

  test('代理（密關鍵幀）拖動：0，seek 本來就快', () {
    expect(compScrubToleranceMs(exact: false, raw: false), 0);
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
