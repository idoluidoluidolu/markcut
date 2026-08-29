// 重現實機 141 兩大主訴：
//  A)「一進場馬上滑就不順」——匯入 2.5 秒（轉檔未完）立刻滑動
//  B)「素材起點（交界）播放卡頓」——同一支影片切段、跨三軌疊放
//    （實機 miss 爆發點全聚在交界窗 0.8~1.3s；佈局三層同檔）
// 結構照抄實機：同 source 多 clip、跨軌、交界密集。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('進場即滑＋同檔切段跨軌交界播放', (tester) async {
    const vid = '/Users/m1/vids_extra/hdra.mp4';
    expect(File(vid).existsSync(), true, reason: '找不到有聲測試片');

    await tester.pumpWidget(
      const MaterialApp(home: VideoEditorScreen(videoPath: vid)),
    );
    // ── A) 進場（時間軸一出現、轉檔一定沒完）立刻滑動 ──
    var waited = 0;
    while (find.byType(TimelineEditor).evaluate().isEmpty && waited < 40) {
      await tester.pump(const Duration(milliseconds: 250));
      waited++;
    }
    expect(
      find.byType(TimelineEditor).evaluate().isNotEmpty,
      true,
      reason: '時間軸 10 秒內沒出現',
    );
    final timeline = find.byType(TimelineEditor);
    final center = tester.getCenter(timeline);
    for (var round = 0; round < 3; round++) {
      final g = await tester.startGesture(center);
      for (var i = 0; i < 14; i++) {
        await g.moveBy(Offset(round.isEven ? -10.0 : 10.0, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    debugPrint('=== 進場即滑完（無炸），等轉檔 ===');

    // 等轉檔全完
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // ── B) 同檔切段跨三軌（交界 0.5/0.8/1.0/1.8/3.0）──
    VideoEditorScreen.debugTimeline!((tl) {
      expect(tl.clips.isNotEmpty, true);
      final c0 = tl.clips.first;
      final si = c0.sourceIndex;
      c0.trimStart = 0;
      c0.trimEnd = 1.0;
      c0.offset = 0;
      c0.track = 0;
      tl.clips.addAll([
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: si,
          trimStart: 1.0,
          trimEnd: 2.5,
          offset: 1.0,
          track: 0,
        ),
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: si,
          trimStart: 2.5,
          trimEnd: 3.5,
          offset: 0.8,
          track: 1,
        ),
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: si,
          trimStart: 3.5,
          trimEnd: 6.0,
          offset: 0.5,
          track: 2,
        ),
      ]);
    });
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    String timeText() {
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText();
        if (s.contains(' / ')) return s;
      }
      return '?';
    }

    // 拉回開頭
    final g0 = await tester.startGesture(center);
    for (var i = 0; i < 40; i++) {
      await g0.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g0.up();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 整段播放穿全部交界
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
      '=== BOUNDARY_PLAY ${DateTime.now().millisecondsSinceEpoch} '
      'took=$took $t1 ===',
    );
    for (var s = 0; s < 5; s++) {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint('=== t+${s + 1}s ${timeText()} ===');
    }
    final t2 = timeText();
    expect(took, true, reason: '交界佈局播放引擎沒接管');
    expect(t2 != t1, true, reason: '交界佈局播放位置沒前進');

    final st = await MetalPreview.stats();
    debugPrint(
      '=== 引擎統計 miss=${st?['pumpMiss']} missWho=${st?['missWho']} '
      'supply=${st?['supply']} maxGap=${st?['maxGapMs']} ===',
    );
    debugPrint('=== 診斷報告 ===\n${Diag.report()}');
  });
}
