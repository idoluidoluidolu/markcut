// 迴歸守門（稽核 #2）：靜音／隱藏軌上唯一的片段被拖走後，那條軌收掉、
// 遞補上來的軌不能繼承靜音／隱藏。
//
// 軌號狀態是綁號碼的：_dropClip 放下之後 compactTracks 把中間空掉的軌
// 收起來、回一張「舊軌號→新軌號」對照表，_remapMuted 照表搬。表裡只有
// 還有片段的軌，被拖空的那條缺席——以前 `map[k] ?? k` 讓它的號碼留在
// 原地，正好落在遞補上來的軌上；匯出照 _mutedTracks／_hiddenTracks 濾，
// 成品就少一軌聲音、整條畫面消失。
//
// 用文字片段跑真的編輯頁（不需要播放器、不組合成），直接呼叫時間軸
// 元件收到的回呼（onToggleMute／onToggleHidden／onDrop）——跟點標籤、
// 拖片段放開走的是同一條路
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';

import 'editor_harness.dart';

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 三段文字片段各佔一軌：A 第 0 軌、B 第 1 軌、C 第 2 軌，都是 0~3 秒
  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await settle(t, 5);
    VideoEditorScreen.debugTimeline!((m) {
      for (var i = 0; i < 3; i++) {
        m.sources.add(
          MediaSource(
            path: '',
            name: 'ABC'[i],
            kind: ClipKind.text,
            duration: 3600,
          ),
        );
        m.clips.add(
          TimelineClip(
            id: i + 1,
            sourceIndex: i,
            trimStart: 0,
            trimEnd: 3,
            offset: 0,
            track: i,
          ),
        );
      }
      m.ensureIdAbove(3);
    });
    await settle(t, 5);
  }

  testWidgets('拖走靜音＋隱藏軌上唯一的片段：那條軌收掉，遞補上來的軌不繼承', (t) async {
    await open(t);
    editorOf(t).onToggleMute(1);
    editorOf(t).onToggleHidden!(1);
    await settle(t, 3);
    expect(editorOf(t).mutedTracks, {1});
    expect(editorOf(t).hiddenTracks, {1});

    // B（id 2）從第 1 軌放到第 0 軌（不插入新軌）：第 1 軌空了，C 遞補上來
    editorOf(t).onDrop(2, 0.0, 0, false);
    await settle(t, 5);
    expect(clipOf(t, 2).track, 0);
    expect(clipOf(t, 3).track, 1, reason: 'C 從第 2 軌遞補到第 1 軌');
    expect(modelOf(t).usedTracks, 2);
    expect(
      editorOf(t).mutedTracks,
      isEmpty,
      reason: '靜音跟著收掉的軌一起消失，不落到 C 頭上',
    );
    expect(editorOf(t).hiddenTracks, isEmpty, reason: '隱藏同理');
    // 讓併批的草稿存檔與提示跑完，別留計時器
    await settle(t, 80);
  });

  testWidgets('對照組：遞補的軌自己的靜音／隱藏要跟著搬到新號碼', (t) async {
    await open(t);
    editorOf(t).onToggleMute(2);
    editorOf(t).onToggleHidden!(2);
    await settle(t, 3);

    editorOf(t).onDrop(2, 0.0, 0, false);
    await settle(t, 5);
    expect(clipOf(t, 3).track, 1);
    expect(
      editorOf(t).mutedTracks,
      {1},
      reason: 'C 的靜音跟著它從第 2 軌搬到第 1 軌',
    );
    expect(editorOf(t).hiddenTracks, {1});
    await settle(t, 80);
  });
}
