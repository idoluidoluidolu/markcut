// 未回報 actualTime 前，不能把整支片長內任意取到的幀當成播放頭附近。
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/scrub_frame_queue.dart';

void main() {
  test('工作檔（密關鍵幀）：維持原本的 150ms', () {
    expect(scrubFrameTolMs(rawSource: false, duration: 12.3), 150);
    expect(scrubFrameTolMs(rawSource: false, duration: 600), 150);
  });

  test('原檔：長片容差仍有限，不放大到整支片長', () {
    expect(scrubFrameTolMs(rawSource: true, duration: 12.3), 250);
    expect(scrubFrameTolMs(rawSource: true, duration: 3600), 250);
    expect(scrubFrameTolMs(rawSource: true, duration: 0.0004), 150);
  });

  test('未知或無效片長不會拋錯或變成無限容差', () {
    expect(scrubFrameTolMs(rawSource: true, duration: double.nan), 150);
    expect(scrubFrameTolMs(rawSource: true, duration: double.infinity), 150);
    expect(scrubFrameTolMs(rawSource: true, duration: -1), 150);
  });

  test('原檔但片子極短：不會低於 150ms（原生端本來的預設）', () {
    expect(scrubFrameTolMs(rawSource: true, duration: 0.05), 150);
    expect(scrubFrameTolMs(rawSource: true, duration: 0), 150);
  });
}
