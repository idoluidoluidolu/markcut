// 重現 build 129 實機回報：「九宮格選最旁邊浮水印被切掉，
// 選回中間還是被切」。逐步驅動＋時間戳 marker，外部截圖對照
// 引擎暫態畫面與讓位後的合成畫面。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('九宮格移動浮水印：暫態與定格畫面都不能切', (tester) async {
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

    await tester.pumpWidget(
      MaterialApp(home: VideoEditorScreen(videoPaths: vids.take(2).toList())),
    );
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    // 底部分頁 → 浮水印 → 位置
    await tester.tap(find.text('浮水印').last);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('位置').last);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final dots = find.byWidgetPredicate(
      (w) => w is InkWell && w.customBorder is CircleBorder,
    );
    final n = dots.evaluate().length;
    debugPrint('=== 九宮格圓點數 $n ===');
    expect(n >= 9, true, reason: '找不到九宮格');

    Future<void> tapDot(int idx, String tag) async {
      await tester.tap(dots.at(idx));
      debugPrint('=== GRID_$tag ${DateTime.now().millisecondsSinceEpoch} ===');
      // 完整走完：接管 600ms 讓位 + 900ms 停穩重烘 + 換手
      for (var i = 0; i < 45; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint(
        '=== GRID_${tag}_SETTLED ${DateTime.now().millisecondsSinceEpoch} ===',
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tapDot(3, 'LEFT'); // 左中
    await tapDot(4, 'CENTER'); // 中央
    await tapDot(3, 'LEFT2'); // 再回左中
    await tapDot(4, 'CENTER2'); // 再回中央
  });
}
