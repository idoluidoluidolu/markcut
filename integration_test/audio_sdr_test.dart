// 重現實機 137：「一進去螢幕就黑掉、播放鍵按下去馬上當機」。
// 關鍵差異：之前所有引擎測試用的是「無聲」測試片——播放接管的
// 音訊分身（audio twin）在模擬機上從來沒真的跑過。這支用「有聲」
// HLG 素材，完全照使用者操作：匯入單支 → 進場 → 播 → 停 → 再播。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/diagnostics.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('單支有聲 SDR：進場不黑、播放不當機、停播再播', (tester) async {
    // 有聲測試片（gen_audio.swift 產）：HLG＋旋轉＋440Hz 正弦波聲軌
    const vid = '/Users/m1/vids_extra/sdra.mp4';
    expect(File(vid).existsSync(), true, reason: '找不到有聲測試片 $vid');

    await tester.pumpWidget(
      const MaterialApp(home: VideoEditorScreen(videoPath: vid)),
    );
    // 等匯入＋工作檔＋HDR 代理＋常駐接管
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    String timeText() {
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText();
        if (s.contains(' / ')) return s;
      }
      return '?';
    }

    // 進場停 6 秒給截圖迴圈拍「進場畫面」——實機回報一進去就黑
    debugPrint(
      '=== ENTRY_HOLD ${DateTime.now().millisecondsSinceEpoch} '
      'active=${MetalPreview.active} ===',
    );
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 按播放——實機回報按下去馬上當機
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
    for (var s = 0; s < 4; s++) {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint('=== t+${s + 1}s ${timeText()} ===');
    }
    final t2 = timeText();
    expect(t2 != t1, true, reason: '有聲素材播放位置沒前進');

    // 暫停 → 再播（實機 136「暫停再播會頓/抖」路徑）
    final pause = find.byIcon(Icons.pause_rounded);
    if (pause.evaluate().isNotEmpty) await tester.tap(pause.first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    debugPrint('=== 暫停後 ${timeText()} ===');
    final play2 = find.byIcon(Icons.play_arrow_rounded);
    expect(play2.evaluate().isNotEmpty, true, reason: '暫停後找不到播放鍵');
    await tester.tap(play2.first);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final t3 = timeText();
    debugPrint('=== 再播 3s 後 $t3 ===');

    final st = await MetalPreview.stats();
    debugPrint('=== 引擎統計 $st ===');
    debugPrint('=== 診斷報告 ===\n${Diag.report()}');
  });
}
