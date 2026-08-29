// 2.0 里程碑③驗證：「一進去就按播放」——轉檔還在跑（層還在吃
// 原檔）引擎也要接管，非代理層走系統播放器過渡供格，畫面不換手。
// 實機 139 的主訴：「都要等讀取完後才會比較順」＝轉檔期走舊合成器
// 又卡又頓（起播 256ms、掉格 330ms、供格連環卡）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/diagnostics.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('進場立刻播放：轉檔期引擎也接管、位置走、不當機', (tester) async {
    const vid = '/Users/m1/vids_extra/hdra.mp4';
    expect(File(vid).existsSync(), true, reason: '找不到有聲測試片');

    await tester.pumpWidget(
      const MaterialApp(home: VideoEditorScreen(videoPath: vid)),
    );
    // 只等 3 秒（轉檔絕對還沒完）就按播放——使用者的真實操作
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    String timeText() {
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText();
        if (s.contains(' / ')) return s;
      }
      return '?';
    }

    final play = find.byIcon(Icons.play_arrow_rounded);
    expect(play.evaluate().isNotEmpty, true, reason: '找不到播放鍵');
    var took = false;
    await tester.tap(play.first);
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (MetalPreview.active) {
        took = true;
        break;
      }
    }
    final t1 = timeText();
    debugPrint(
      '=== INSTANT_PLAY ${DateTime.now().millisecondsSinceEpoch} '
      'took=$took $t1 ===',
    );
    // 播 5 秒真實時間（橫跨轉檔完成的瞬間——過渡供格→代理無縫）
    for (var s = 0; s < 5; s++) {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint('=== t+${s + 1}s ${timeText()} ===');
    }
    final t2 = timeText();
    expect(t2 != t1, true, reason: '轉檔期播放位置沒前進');

    // 暫停 → 等轉檔全完 → 再播（升級成解碼佇列的路）
    final pause = find.byIcon(Icons.pause_rounded);
    if (pause.evaluate().isNotEmpty) await tester.tap(pause.first);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final play2 = find.byIcon(Icons.play_arrow_rounded);
    if (play2.evaluate().isNotEmpty) await tester.tap(play2.first);
    final t3 = timeText();
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final t4 = timeText();
    debugPrint('=== 轉檔完再播 $t3 → $t4 ===');
    expect(t4 != t3, true, reason: '轉檔完成後再播位置沒前進');

    final st = await MetalPreview.stats();
    debugPrint('=== 引擎統計 $st ===');
    debugPrint('=== 診斷報告 ===\n${Diag.report()}');
  });
}
