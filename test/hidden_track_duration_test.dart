// 迴歸守門（稽核 #5）：關閉顯示的軌不能決定專案總長。
//
// 眼睛關掉＝整條軌從預覽和匯出消失（畫面與聲音都不進），合成也只鋪到
// 可見片段的結尾（CompPlayer.padTo 跳過隱藏軌）；但播放時鐘、匯出的
// timelineDuration、浮水印「跟到結尾」以前都看 _tl.duration（掃全部
// 片段）——隱藏一條比影片長的軌，播到影片結尾後畫面黑著走完那截、
// 成品多一段黑尾巴、浮水印也蓋到那段。現在這幾處看
// TimelineModel.durationSkipping（編輯器的 _visDur）。
//
// 模型層先釘 durationSkipping；再走真的編輯器：影片 0~5、文字 0~7 在另
// 一軌，關掉文字軌後播放要停在 5.0，浮水印範圍與總長讀數也是 5.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';

import 'editor_harness.dart';

void main() {
  group('TimelineModel.durationSkipping', () {
    test('跳過的軌不算進總長；duration 本身照舊掃全部片段', () {
      final tl = TimelineModel();
      tl.sources.add(
        MediaSource(path: 'v', name: 'v', kind: ClipKind.video, duration: 10),
      );
      tl.sources.add(
        MediaSource(path: 'a', name: 'a', kind: ClipKind.audio, duration: 10),
      );
      tl.clips.add(
        TimelineClip(
          id: 1,
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 5,
          offset: 0,
          track: 0,
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: 2,
          sourceIndex: 1,
          trimStart: 0,
          trimEnd: 7,
          offset: 0,
          track: 1,
        ),
      );
      expect(tl.duration, 7.0);
      expect(tl.durationSkipping(const {}), 7.0);
      expect(tl.durationSkipping({1}), 5.0, reason: '藏掉長的那軌：只剩影片');
      expect(tl.durationSkipping({0}), 7.0);
      expect(tl.durationSkipping({0, 1}), 0.0);
      expect(tl.duration, 7.0, reason: '時間軸畫面照舊看全部片段');
    });
  });

  group('編輯器', () {
    late FakeComp comp;

    setUpAll(() {
      final b = TestWidgetsFlutterBinding.ensureInitialized();
      bigPhoneView(b);
      mockEditorPlugins(b);
    });

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Diag.playerLayer.value = false;
      // 合成只鋪到可見片段的結尾：藏掉文字軌之後就是影片的 5 秒
      comp = FakeComp(TestWidgetsFlutterBinding.ensureInitialized())
        ..duration = 5.0
        ..capAtEnd = true
        ..install();
    });

    tearDown(() => comp.uninstall());

    testWidgets('關掉比影片長的軌：播放停在可見結尾，浮水印與總長讀數跟著變', (t) async {
      await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
      await tick(t, 5);
      VideoEditorScreen.debugTimeline!((tl) {
        tl.sources.add(
          MediaSource(
            path: '/v.mp4',
            name: 'v',
            kind: ClipKind.video,
            duration: 100,
            workPath: '/v.work.mp4',
          ),
        );
        tl.clips.add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 5,
            offset: 0,
            track: 0,
          ),
        );
        tl.sources.add(
          MediaSource(
            path: '',
            name: 'hi',
            kind: ClipKind.text,
            duration: 3600,
          ),
        );
        tl.clips.add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: 1,
            trimStart: 0,
            trimEnd: 7,
            offset: 0,
            track: 1,
          ),
        );
      });
      await tick(t, 15);
      expect(modelOf(t).duration, 7.0);
      expect(
        editorOf(t).watermark?.end,
        closeTo(7.0, 1e-6),
        reason: '沒藏東西時浮水印跟到 7.0',
      );
      expect(find.textContaining('/ 00:07.0'), findsOneWidget);

      editorOf(t).onToggleHidden!(1);
      await tick(t, 15);
      expect(editorOf(t).hiddenTracks, {1});
      expect(modelOf(t).duration, 7.0, reason: '時間軸本身還是 7 秒（片段還在軸上、還能編輯）');
      expect(
        editorOf(t).watermark?.end,
        closeTo(5.0, 1e-6),
        reason: '浮水印只蓋到可見結尾',
      );
      expect(find.textContaining('/ 00:05.0'), findsOneWidget);

      await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
      await tick(t, 6, 33);
      expect(isPlaying(), isTrue);
      var stopped = false;
      for (var i = 0; i < 260; i++) {
        await t.pump(const Duration(milliseconds: 33));
        if (!isPlaying()) {
          stopped = true;
          break;
        }
      }
      expect(stopped, isTrue, reason: '走到終點要自己停下');
      await tick(t, 5);
      expect(playheadOf(t), closeTo(5.0, 1e-6), reason: '停在可見結尾，不是對著黑畫面走到 7.0');

      // 打開回來：總長回到 7
      editorOf(t).onToggleHidden!(1);
      await tick(t, 15);
      expect(editorOf(t).hiddenTracks, isEmpty);
      expect(editorOf(t).watermark?.end, closeTo(7.0, 1e-6));
      expect(find.textContaining('/ 00:07.0'), findsOneWidget);

      // 再藏一次，把「短短一截」的浮水印範圍整條往後拖：上限也是可見總長。
      // 夾到 _tl.duration 的話起點會落進隱藏軌的尾巴（6.0），終點卻被
      // _wmEndEff 拉回可見結尾 5.0——匯出收到一組起點大於終點的範圍。
      // 範圍要先縮短才碰得到：跟到結尾的滿長範圍本來就推不出去
      //（放最後做：拖過就是把「跟到結尾」寫成死數字，前面的斷言要的是 null）
      editorOf(t).onToggleHidden!(1);
      await tick(t, 10);
      editorOf(t).onTrimWmStart!();
      editorOf(t).onTrimWm(-4.0, false); // 右把手往左：範圍剩 0~1
      // 拖曳中只有時間軸與預覽層重畫（_setTimelineLive），頁面其他部分
      // 要放手才補上；這裡是透過 widget 讀值的，不放手會讀到上一幀那份
      editorOf(t).onWmGestureEnd!();
      await tick(t, 6);
      expect(editorOf(t).watermark!.end, closeTo(1.0, 0.05), reason: '先縮短範圍');

      editorOf(t).onMoveWm(6.5);
      editorOf(t).onWmGestureEnd!();
      await tick(t, 6);
      final wm = editorOf(t).watermark!;
      expect(wm.start, lessThanOrEqualTo(5.0 + 1e-6), reason: '起點不進隱藏的尾巴');
      expect(wm.end, greaterThanOrEqualTo(wm.start), reason: '起點不能跑到終點後面');
      await tick(t, 100);
    });
  });
}
