// 重現實機 136：三層疊放多軌播放「黑畫面＋暫停再播抖＋閃退」。
// 佈局照抄 136 診斷：z0@0.0~6.0（主軌）、z1@3.0~9.0（同一個檔！雙
// reader 同檔）、z2@0.6~2.1（短片疊最上）。之前所有引擎測試都是
// 單軌串接，多軌這條路徑從來沒進過綠燈——這支補上。
//
// 壓力點：
//  1. 快速跳滑 ×8 → reader start()/stop() 高頻開關（世代競態閃退區）
//  2. 播放穿過全部交界（0.6 / 2.1 / 3.0 / 6.0）到底
//  3. 播→停 ×5 快速循環（暫停抖動與讓位對齊）
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

  testWidgets('三層疊放多軌：滑動壓力→整段播放→播停循環，不閃退不黑', (
    tester,
  ) async {
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
    expect(vids.length >= 2, true, reason: '找不到測試影片');

    // 136 同款：前兩層同一個檔案（雙 reader 讀同檔）
    await tester.pumpWidget(
      MaterialApp(
        home: VideoEditorScreen(videoPaths: [vids[0], vids[0], vids[1]]),
      ),
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // 疊放佈局：測試鉤子直接改軌（UI 手勢組不出穩定疊放）。
    // 匯入的工作檔轉檔是背景事件，完成時可能把片段重新排位——
    // 所以套完等一輪、再套一次、驗證穩定才算就緒
    void applyLayout() {
      VideoEditorScreen.debugTimeline!((tl) {
        final cs = [...tl.clips]..sort((a, b) => a.id.compareTo(b.id));
        expect(cs.length >= 3, true, reason: '匯入後不足 3 個片段');
        cs[1].track = 1;
        cs[1].offset = 3.0;
        cs[2].track = 2;
        cs[2].offset = 0.6;
        cs[2].trimEnd = cs[2].trimStart + 1.5;
      });
    }

    applyLayout();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    applyLayout();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    var stable = true;
    VideoEditorScreen.debugTimeline!((tl) {
      final cs = [...tl.clips]..sort((a, b) => a.id.compareTo(b.id));
      stable =
          cs.length >= 3 &&
          (cs[1].offset - 3.0).abs() < 0.01 &&
          (cs[2].offset - 0.6).abs() < 0.01 &&
          cs[1].track == 1 &&
          cs[2].track == 2;
    });
    expect(stable, true, reason: '疊放佈局被背景事件改掉，起播前不成立');
    debugPrint('=== 疊放佈局就緒 active=${MetalPreview.active} ===');

    String timeText() {
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText();
        if (s.contains(' / ')) return s;
      }
      return '?';
    }

    final timeline = find.byType(TimelineEditor);
    final center = tester.getCenter(timeline);

    // ── 壓力 1：快速跳滑（reader 高頻開關）──
    for (var round = 0; round < 8; round++) {
      final g = await tester.startGesture(center);
      final dx = round.isEven ? -30.0 : 30.0;
      for (var i = 0; i < 6; i++) {
        await g.moveBy(Offset(dx, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 120));
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint('=== 跳滑壓力完（無閃退）===');

    // 拉回開頭準備整段播放
    final g0 = await tester.startGesture(center);
    for (var i = 0; i < 50; i++) {
      await g0.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g0.up();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // ── 壓力 2：整段播放穿過所有交界 ──
    var took = false;
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (MetalPreview.active) {
        took = true;
        break;
      }
    }
    final t1 = timeText();
    debugPrint(
      '=== PLAY_START ${DateTime.now().millisecondsSinceEpoch} '
      'took=$took $t1 ===',
    );
    // 播 11 秒真實時間（9 秒內容＋餘裕），中途每秒報位置
    for (var s = 0; s < 11; s++) {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint('=== t+${s + 1}s ${timeText()} ===');
    }
    final t2 = timeText();
    expect(took, true, reason: '多軌疊放播放引擎沒接管');
    expect(t2 != t1, true, reason: '多軌播放位置沒前進');

    // ── 壓力 3：播→停 ×5 快速循環 ──
    for (var round = 0; round < 5; round++) {
      // 先拉回中段（每輪從 z1/z2 疊放區起播）
      final gg = await tester.startGesture(center);
      for (var i = 0; i < 20; i++) {
        await gg.moveBy(Offset(round.isEven ? 25.0 : -10.0, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gg.up();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final play = find.byIcon(Icons.play_arrow_rounded);
      if (play.evaluate().isEmpty) continue;
      await tester.tap(play.first);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final pause = find.byIcon(Icons.pause_rounded);
      if (pause.evaluate().isNotEmpty) await tester.tap(pause.first);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint('=== 播停循環 ${round + 1}/5 ${timeText()} ===');
    }

    final st = await MetalPreview.stats();
    debugPrint('=== 引擎統計 $st ===');
    debugPrint('=== 診斷報告 ===\n${Diag.report()}');
    // 走到這裡＝三段壓力全程沒有閃退；黑畫面由外部截圖迴圈驗證
  });
}
