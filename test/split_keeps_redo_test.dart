// 迴歸守門（稽核 #17f）：靠邊切割「切不成」不能把重做歷史清掉。
//
// _splitAtPlayhead 以前先 _pushUndo 再 splitAt，切不成才把快照收回——
// 但 _pushUndo 已經把 _redoStack 清掉了，收回快照救不回重做。現在先問
// TimelineModel.canSplitAt 再拍快照
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';

import 'editor_harness.dart';

void main() {
  group('TimelineModel.canSplitAt', () {
    test('兩半各至少 0.2 秒；splitAt 切不成的條件跟它同一套', () {
      final tl = TimelineModel();
      tl.sources.add(
        MediaSource(path: '', name: 'hi', kind: ClipKind.text, duration: 3600),
      );
      final c = TimelineClip(
        id: 1,
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 4,
        offset: 1,
        track: 0,
      );
      tl.clips.add(c);
      expect(tl.canSplitAt(c, 1.1), isFalse);
      expect(tl.canSplitAt(c, 4.9), isFalse);
      // 1.25 而不是 1.2：1.2−1.0 在浮點裡是 0.1999…，本來就切不成
      expect(tl.canSplitAt(c, 1.25), isTrue);
      expect(tl.canSplitAt(c, 3.0), isTrue);
      expect(tl.splitAt(c, 1.1), isNull);
      expect(tl.clips.length, 1, reason: '切不成什麼都不動');
      expect(tl.splitAt(c, 3.0), isNotNull);
      expect(tl.clips.length, 2);
    });
  });

  group('編輯器', () {
    setUpAll(() {
      final b = TestWidgetsFlutterBinding.ensureInitialized();
      bigPhoneView(b);
      mockEditorPlugins(b);
    });
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('有重做可用時靠邊切一下：切不成、重做還在；真的切成才清掉', (t) async {
      await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
      await settle(t, 5);
      VideoEditorScreen.debugTimeline!((m) {
        m.sources.add(
          MediaSource(
            path: '',
            name: 'hi',
            kind: ClipKind.text,
            duration: 3600,
          ),
        );
        m.clips.add(
          TimelineClip(
            id: 1,
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 4,
            offset: 0,
            track: 0,
          ),
        );
        m.ensureIdAbove(1);
      });
      await settle(t, 5);

      // 弄出一份重做：拍一份快照（修剪起手）再上一步。起手本身不重建
      // 畫面，補一步 0 秒的修剪讓「上一步」鈕亮起來
      editorOf(t).onTrimStart!();
      editorOf(t).onTrim(1, 0.0, false);
      // 修剪把手放手才整頁 setState（_trimGestureEnd）：不放手的話
      // 「上一步」鈕還是上一幀的樣子
      editorOf(t).onTrimEnd!();
      await settle(t, 3);
      expect(undoEnabled(t), isTrue);
      await t.tap(undoButton());
      await settle(t, 6);
      expect(redoEnabled(t), isTrue);

      // 選片段、指針停在 0.1 秒（離頭不到 0.2）、按切割。
      // 先放大：初始縮放最多 60px/s，播放頭 12px 的吸附半徑就是 0.2 秒，
      // 靠邊的點全被吸到邊上——使用者要靠邊切也得先放大
      await t.tapAt(t.getCenter(clipBlock(1)));
      await settle(t, 6);
      editorOf(t).onZoom!(400);
      await settle(t, 3);
      editorOf(t).onSeek(0.1);
      await settle(t, 8);
      expect(playheadOf(t), closeTo(0.1, 1e-6));
      // 工具列的「切割」（剪刀圖示是「剪輯」分頁的，不是它）
      await t.tap(find.byIcon(Icons.splitscreen));
      await settle(t, 6);
      expect(find.textContaining('太靠近邊緣'), findsOneWidget);
      expect(modelOf(t).clips.length, 1, reason: '沒切成');
      expect(redoEnabled(t), isTrue, reason: '切不成不是一個編輯步驟，重做要留著');

      // 對照：切得成才是一步，重做這時才清掉
      editorOf(t).onSeek(2.0);
      await settle(t, 8);
      // 工具列的「切割」（剪刀圖示是「剪輯」分頁的，不是它）
      await t.tap(find.byIcon(Icons.splitscreen));
      await settle(t, 6);
      expect(modelOf(t).clips.length, 2);
      expect(redoEnabled(t), isFalse);
      await settle(t, 80);
    });
  });
}
