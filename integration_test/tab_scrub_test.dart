// 重現 135 實機：「回到編輯有時無法右滑讓指針往左走，會卡住」。
// 疑似觸發態：播放過→暫停→切分頁→回剪輯→右滑。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/widgets/timeline_editor.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('播放→暫停→切分頁→回剪輯→右滑，指針要能往左', (tester) async {
    var vids = <String>[];
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
    expect(vids.length >= 2, true, reason: '找不到測試影片');

    await tester.pumpWidget(
      MaterialApp(home: VideoEditorScreen(videoPaths: vids.take(2).toList())),
    );
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    String timeText() {
      for (final e in find.byType(RichText).evaluate()) {
        final s = (e.widget as RichText).text.toPlainText();
        if (s.contains(' / ')) return s;
      }
      return '?';
    }

    final timeline = find.byType(TimelineEditor);
    final center = tester.getCenter(timeline);

    // 先滑到中段（之後才有「往左」的空間）
    final g0 = await tester.startGesture(center);
    for (var i = 0; i < 40; i++) {
      await g0.moveBy(const Offset(-8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g0.up();
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 播放 2 秒 → 暫停
    await tester.tap(find.byIcon(Icons.play_arrow_rounded).first);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final pause = find.byIcon(Icons.pause_rounded);
    if (pause.evaluate().isNotEmpty) await tester.tap(pause.first);
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 切浮水印分頁 → 回剪輯
    await tester.tap(find.text('浮水印').last);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('剪輯').last);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 右滑（指針往左）——135 實機回報卡住的手勢
    final before = timeText();
    final g = await tester.startGesture(center);
    for (var i = 0; i < 40; i++) {
      await g.moveBy(const Offset(8, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final after = timeText();
    debugPrint('=== 右滑前後位置 $before → $after ===');
    expect(after != before, true, reason: '右滑後指針沒動——卡住重現！');
  });
}
