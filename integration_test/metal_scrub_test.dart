// 模擬器實機驗證：時間軸滑動 → Metal 預覽引擎接管。
//
// 跑法（雲端 Mac）：
//   flutter test integration_test/metal_scrub_test.dart -d <模擬器UDID>
//
// 素材約定：模擬器上先用 App 匯入過影片（Documents/picked_images 會留
// 拷貝），測試直接撿那裡的 mp4 用——不用把測試片打包進 App。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('時間軸滑動時 Metal 引擎接管，放開後讓位', (tester) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/picked_images');
    final vids =
        (dir.existsSync()
              ? dir
                    .listSync()
                    .whereType<File>()
                    .map((f) => f.path)
                    .where((p) => p.endsWith('.mp4'))
                    .toList()
              : <String>[])
          ..sort();
    expect(
      vids.length >= 2,
      true,
      reason: '要先在模擬器的 App 裡匯入過至少兩支影片（picked_images 是空的）',
    );

    await tester.pumpWidget(
      MaterialApp(home: VideoEditorScreen(videoPaths: vids.take(2).toList())),
    );

    // 等匯入（探測、工作檔、合成播放器）就緒。pumpAndSettle 等不完
    // ——編輯器常駐動畫與計時器，用固定節拍拉真實時間
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    debugPrint('=== 匯入等待結束，開始滑動 ===');

    final timeline = find.byType(TimelineEditor);
    expect(timeline, findsOneWidget);
    final center = tester.getCenter(timeline);

    // 真手勢：快起手（避開長按判定）、慢慢掃 2.4 秒，
    // 中途逐步檢查引擎有沒有亮起來
    Duration? tookOver;
    final sw = Stopwatch()..start();
    final g = await tester.startGesture(center);
    for (var i = 0; i < 48; i++) {
      await g.moveBy(const Offset(-6, 0));
      await tester.pump(const Duration(milliseconds: 50));
      if (tookOver == null && MetalPreview.active) {
        tookOver = sw.elapsed;
        debugPrint('=== Metal 接管於 ${tookOver.inMilliseconds}ms ===');
      }
    }
    await g.up();
    await tester.pump();

    final active = MetalPreview.active;
    debugPrint('=== 放開瞬間 MetalPreview.active=$active ===');

    // 放開 300ms 後引擎要讓位（合成播放器回來畫）
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final released = MetalPreview.active;
    debugPrint('=== 放開後 0.8s MetalPreview.active=$released ===');

    // 第二次滑動：引擎已建好，接管要在 300ms 內
    Duration? second;
    final sw2 = Stopwatch()..start();
    final g2 = await tester.startGesture(center);
    for (var i = 0; i < 24; i++) {
      await g2.moveBy(const Offset(5, 0));
      await tester.pump(const Duration(milliseconds: 50));
      if (second == null && MetalPreview.active) {
        second = sw2.elapsed;
        debugPrint('=== 第二次接管於 ${second.inMilliseconds}ms ===');
      }
    }
    await g2.up();
    await tester.pump();

    debugPrint('=== 診斷報告 ===\n${Diag.report()}');

    expect(tookOver, isNotNull, reason: '滑動全程 Metal 引擎都沒接管');
    expect(released, false, reason: '放開後引擎沒讓位，會蓋住播放畫面');
    expect(second, isNotNull, reason: '第二次滑動引擎沒接管');
  });
}
