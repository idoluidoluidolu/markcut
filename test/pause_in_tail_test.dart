// 迴歸守門（稽核 #9）：馬賽克拖過影片結尾之後，在尾巴按暫停，指針不能
// 被拉回影片結尾。
//
// 合成只鋪到最後一段影片的結尾（馬賽克不算，見 CompPlayer.padTo），
// 時間軸可以更長。播到尾巴時播放器早就停在合成結尾、Dart 的時鐘自己
// 走完尾巴——_syncFromComp 播放中有這條豁免，_pause 的「用播放器停點
// 回填」卻沒有：差不到 1 秒就照回填，5.6 被拉回 5.0（探針實測 5.61 →
// 5.0）。
//
// 假的 markcut/comp 通道把 position 釘在合成結尾（真的 AVPlayer 播到
// item 尾端就是這樣停住），走真的編輯器：播、等指針過了影片結尾、按暫停
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';

import 'editor_harness.dart';

void main() {
  late FakeComp comp;

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 測試環境沒有真的原生 UiKitView：合成畫面走 Texture
    Diag.playerLayer.value = false;
    comp = FakeComp(TestWidgetsFlutterBinding.ensureInitialized())
      ..duration = 5.0
      ..capAtEnd = true
      ..install();
  });

  tearDown(() => comp.uninstall());

  testWidgets('影片 5 秒、馬賽克 4~8 秒：播過 5 秒後按暫停，指針留在尾巴', (t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((tl) {
      // 給 workPath＝不探 HDR、不碰檔案系統
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
          name: '馬賽克',
          kind: ClipKind.mosaic,
          duration: 3600,
          mosaicStyle: MosaicStyle(),
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 1,
          trimStart: 0,
          trimEnd: 4,
          offset: 4,
          track: 1,
        ),
      );
    });
    await tick(t, 15);
    expect(comp.builds, 1, reason: '合成播放器要組起來');
    expect(modelOf(t).duration, 8.0, reason: '時間軸 8 秒、合成只有 5 秒');

    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 6, 33);
    expect(isPlaying(), isTrue, reason: '按了播放要在播');
    // 走進尾巴（過影片結尾半秒以上）
    var frames = 0;
    while (playheadOf(t) < 5.6 && frames < 300) {
      await t.pump(const Duration(milliseconds: 33));
      frames++;
    }
    expect(isPlaying(), isTrue, reason: '尾巴要讓時鐘自己走完，不是停在影片結尾');
    final atPause = playheadOf(t);
    expect(atPause, greaterThanOrEqualTo(5.6));

    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await tick(t, 8, 33);
    expect(isPlaying(), isFalse);
    expect(
      playheadOf(t),
      closeTo(atPause, 0.15),
      reason: '暫停不能拿播放器的停點（合成結尾 5.0）把指針從尾巴拉回去',
    );
    expect(playheadOf(t), greaterThan(5.5));
    // 收尾：讓排著的計時器（存草稿之類）跑掉
    await tick(t, 100);
  });
}
