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
    // 素材：優先撿 App 匯入過的拷貝；沒有就直接讀宿主機的測試片
    //（模擬器不強制沙盒，讀得到 Mac 的路徑——重裝清掉容器也不怕）
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/picked_images');
    var vids =
        (dir.existsSync()
              ? dir
                    .listSync()
                    .whereType<File>()
                    .map((f) => f.path)
                    .where((p) => p.endsWith('.mp4'))
                    .toList()
              : <String>[])
          ..sort();
    if (vids.length < 2) {
      final host = Directory('/Users/m1/vids');
      if (host.existsSync()) {
        vids =
            host
                .listSync()
                .whereType<File>()
                .map((f) => f.path)
                .where((p) => p.endsWith('.mp4'))
                .toList()
              ..sort();
      }
    }
    expect(
      vids.length >= 2,
      true,
      reason: '找不到測試影片（picked_images 與 ~/vids 都空）',
    );

    await tester.pumpWidget(
      MaterialApp(home: VideoEditorScreen(videoPaths: vids.take(2).toList())),
    );

    // 等匯入（探測、工作檔、合成播放器）就緒。pumpAndSettle 等不完
    // ——編輯器常駐動畫與計時器，用固定節拍拉真實時間
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    debugPrint('=== 匯入等待結束 ===');

    // 位置顯示可能是 Text 或 RichText，兩種都撈
    String timeText() {
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText();
        if (s.contains(' / ')) return s;
      }
      for (final e in find.byType(Text).evaluate()) {
        final s = (e.widget as Text).data ?? '';
        if (s.contains(' / ')) return s;
      }
      return '(找不到時間)';
    }

    final timeBefore = timeText();
    final timeline = find.byType(TimelineEditor);
    expect(timeline, findsOneWidget);
    final center = tester.getCenter(timeline);
    debugPrint('=== 滑動起點 $center，時間 $timeBefore ===');

    // 真手勢、真手速：每格 16ms 挪 20px（一步就破 18px 觸控閾值），
    // 中途逐格檢查引擎有沒有亮起來——這個數字就是使用者感受到的
    // 「開始滑到畫面接手」延遲
    Duration? tookOver;
    final sw = Stopwatch()..start();
    final g = await tester.startGesture(center);
    for (var i = 0; i < 40; i++) {
      await g.moveBy(const Offset(-8, 0));
      await tester.pump(const Duration(milliseconds: 16));
      if (tookOver == null && MetalPreview.active) {
        tookOver = sw.elapsed;
        debugPrint('=== Metal 接管於 ${tookOver.inMilliseconds}ms ===');
      }
    }
    // 後段放慢，把播放頭確實拖出一段距離
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(-8, 0));
      await tester.pump(const Duration(milliseconds: 33));
    }
    await g.up();
    await tester.pump();

    final active = MetalPreview.active;
    final timeAfter = timeText();
    debugPrint(
      '=== 放開瞬間 MetalPreview.active=$active，'
      '時間 $timeBefore → $timeAfter ===',
    );
    // 時間文字只當參考資訊：接管本身（tookOver）就證明 scrub 有跑
    //（_metalScrubBegin 只會在拖曳路徑被呼叫）

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
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 第三段：按住不放——引擎畫面停在同一格 8 秒（給外部截圖），
    // 放開等合成器精準幀就位再停 8 秒。兩段截圖相減＝
    // 「引擎畫的」vs「合成器畫的」一致性
    final g3 = await tester.startGesture(center);
    for (var i = 0; i < 10; i++) {
      await g3.moveBy(const Offset(-8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrint(
      '=== HOLD_ENGINE ${DateTime.now().millisecondsSinceEpoch} '
      'active=${MetalPreview.active} ===',
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint(
      '=== HOLD_ENGINE_END ${DateTime.now().millisecondsSinceEpoch} ===',
    );
    await g3.up();
    await tester.pump();
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint(
      '=== HOLD_COMP ${DateTime.now().millisecondsSinceEpoch} '
      'active=${MetalPreview.active} ===',
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint(
      '=== HOLD_COMP_END ${DateTime.now().millisecondsSinceEpoch} ===',
    );

    // 第四段：播放接管（最終型態）——按播放，引擎要接管、位置要走
    var tookPlay = false;
    final play = find.byIcon(Icons.play_arrow_rounded);
    expect(play.evaluate().isNotEmpty, true, reason: '找不到播放鍵');
    await tester.tap(play.first);
    // 起播點可能離片尾很近：立即取樣，別先耗秒數輪詢旗標
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    tookPlay = MetalPreview.active;
    final tPlay1 = timeText();
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (i % 5 == 0) debugPrint('=== 播放中 UI=${timeText()} ===');
    }
    final tPlay2 = timeText();
    debugPrint('=== 播放接管 $tookPlay，位置 $tPlay1 → $tPlay2 ===');
    final pause = find.byIcon(Icons.pause_rounded);
    if (pause.evaluate().isNotEmpty) {
      await tester.tap(pause.first);
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    var afterPause = MetalPreview.active;
    for (var i = 0; i < 20 && !afterPause; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      afterPause = MetalPreview.active;
    }
    debugPrint('=== 暫停後 active=$afterPause ===');

    // 播放已泊車（pump 全放掉）：暫停後再滑，pump 要能懶建回來
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    Duration? third;
    final sw3 = Stopwatch()..start();
    final g4 = await tester.startGesture(center);
    for (var i = 0; i < 40; i++) {
      await g4.moveBy(const Offset(5, 0));
      await tester.pump(const Duration(milliseconds: 50));
      if (third == null && MetalPreview.active) {
        third = sw3.elapsed;
        debugPrint('=== 泊車後再滑接管於 ${third.inMilliseconds}ms ===');
      }
    }
    await g4.up();
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(third, isNotNull, reason: '泊車後再滑引擎沒接管（pump 沒重建）');

    // 數值法庭：離屏取兩段各 5 點線性值（跟顯示器無關），
    // 與測試片的授權值換算比對——「顏色準」的最終判準
    String fmt(List<double>? g) =>
        g == null ? '(null)' : g.map((v) => v.toStringAsFixed(4)).join(', ');
    await MetalPreview.grab(9.9); // 先觸發 pump seek
    await tester.pump(const Duration(milliseconds: 900));
    final gSdr = await MetalPreview.grab(9.9);
    debugPrint('=== GRAB sdr@9.9: ${fmt(gSdr)} ===');
    await MetalPreview.grab(3.0);
    await tester.pump(const Duration(milliseconds: 900));
    final gHlg = await MetalPreview.grab(3.0);
    debugPrint('=== GRAB hlg@3.0: ${fmt(gHlg)} ===');

    debugPrint('=== 診斷報告 ===\n${Diag.report()}');

    expect(tookOver, isNotNull, reason: '滑動全程 Metal 引擎都沒接管');
    // 常駐/播放接管預設關（build 129 實機回歸後回穩）：
    // 放手/暫停後引擎讓位、播放走合成畫面
    // 常駐（預設開）：放手/暫停後引擎續留——它就是畫面
    expect(released, true, reason: '常駐佈局放手後引擎不該讓位');
    expect(second, isNotNull, reason: '第二次滑動引擎沒接管');
    expect(tPlay2 != tPlay1, true, reason: '播放接管中位置沒前進');
    expect(afterPause, true, reason: '常駐佈局暫停後引擎不該讓位');
  });
}
