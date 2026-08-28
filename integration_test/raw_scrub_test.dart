// 「匯入即滑」驗證：疏關鍵幀原檔（模擬 iPhone 4K HEVC 特性）
// 在工作檔還沒轉好時就滑——關鍵幀貼齊要讓引擎瞬間接管、畫面
// 有內容。剪映「進去馬上能滑」對標。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/widgets/timeline_editor.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('疏關鍵幀原檔：匯入即滑（不等工作檔）', (tester) async {
    final raw = File('/Users/m1/vids_raw/a_sparse.mp4');
    expect(raw.existsSync(), true, reason: '找不到疏關鍵幀測試片');

    await tester.pumpWidget(
      MaterialApp(home: VideoEditorScreen(videoPath: raw.path)),
    );
    // 只等合成就緒（~2-4s），「不等」工作檔——這正是測試目的
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    debugPrint('=== 早期等待結束（工作檔應該還沒好） ===');

    final timeline = find.byType(TimelineEditor);
    expect(timeline, findsOneWidget);
    final center = tester.getCenter(timeline);

    Duration? tookOver;
    final sw = Stopwatch()..start();
    final g = await tester.startGesture(center);
    for (var i = 0; i < 50; i++) {
      await g.moveBy(const Offset(-8, 0));
      await tester.pump(const Duration(milliseconds: 16));
      if (tookOver == null && MetalPreview.active) {
        tookOver = sw.elapsed;
        debugPrint('=== 原檔接管於 ${tookOver.inMilliseconds}ms ===');
      }
    }
    // 按住停 3 秒（外部截圖驗畫面有內容非黑）
    debugPrint(
      '=== RAW_HOLD ${DateTime.now().millisecondsSinceEpoch} '
      'active=${MetalPreview.active} ===',
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(tookOver, isNotNull, reason: '原檔（疏關鍵幀）滑動引擎沒接管——匯入即滑失敗');
    expect(
      tookOver!.inMilliseconds < 1500,
      true,
      reason: '原檔接管太慢（${tookOver.inMilliseconds}ms）',
    );
  });
}
