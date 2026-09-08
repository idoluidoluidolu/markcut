// 拖曳幀的容忍值：原檔期關鍵幀貼齊、工作檔逐格精準（見 scrubFrameTolMs）。
//
// 實測回報「匯入多支影片後進去馬上左右滑動預覽超頓，要等一段時間才
// 回覆」：秒進期間工作檔還在背景轉，拖曳幀從 4K 原檔用 150ms 的容忍抽，
// 每一格都得從前一個關鍵幀（GOP 一兩秒）解到目標，還跟轉檔搶解碼器
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/scrub_frame_queue.dart';

void main() {
  test('工作檔（密關鍵幀）：維持原本的 150ms', () {
    expect(scrubFrameTolMs(rawSource: false, duration: 12.3), 150);
    expect(scrubFrameTolMs(rawSource: false, duration: 600), 150);
  });

  test('原檔：容忍整支長度＝直接拿最近的關鍵幀', () {
    expect(scrubFrameTolMs(rawSource: true, duration: 12.3), 12300);
    expect(scrubFrameTolMs(rawSource: true, duration: 0.0004), 150);
  });

  test('原檔但片子極短：不會低於 150ms（原生端本來的預設）', () {
    expect(scrubFrameTolMs(rawSource: true, duration: 0.05), 150);
    expect(scrubFrameTolMs(rawSource: true, duration: 0), 150);
  });
}
