// 預覽畫框跟成品同一個形狀：「原始」比例認最底層、最早出現的那段畫面
//（匯出 computeCanvasSize、合成播放器都認這段）。
//
// 實機回報（10-27，iPhone）：底下一軌橫式街景、上面一軌直式人像——停著
// 是橫的，一播放預覽框就變直的，橫式的合成畫面縮在直框中間。預覽框以前
// 認的是「播放頭底下最上層的影片」，上層那段一開始播就換成它的比例；
// 合成跟匯出照舊是橫的，框跟畫面對不上。
//
// 守的是：
//   1. 上層直式那段晚一點才開始：停著、播放中、播過它再停下，框都是
//      橫的、大小不變
//   2. 兩段都從 0 開始（實機的排法）：一進來就是橫的
//   3. 底層是直式圖片、上面疊橫式影片：框照圖片是直的，合成也收到這個
//      比例（合成只挑影片當底，不送就會照橫式影片組）
//   4. 底層就是影片的一般情形不送比例給合成：原生量的是實際播的那支檔，
//      Dart 記的尺寸跟工作檔可能差一兩個像素，硬送會在邊上多一條黑線
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
    Diag.playerLayer.value = false;
    comp = FakeComp(TestWidgetsFlutterBinding.ensureInitialized())
      ..duration = 6.8
      ..width = 1920
      ..height = 1080
      ..install();
  });

  tearDown(() => comp.uninstall());

  /// 底下一軌橫式街景（1920×1080、0~6.8 秒），上面一軌直式螢幕錄影
  ///（886×1920、3 秒長，從 [topAt] 秒開始）
  Future<void> openTwoTracks(WidgetTester t, {double topAt = 0}) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources
        ..add(
          MediaSource(
            path: '/street.mp4',
            name: 'street',
            kind: ClipKind.video,
            duration: 6.8,
            w: 1920,
            h: 1080,
            workPath: '/street.work.mp4',
          ),
        )
        ..add(
          MediaSource(
            path: '/girl.mp4',
            name: 'girl',
            kind: ClipKind.video,
            duration: 3,
            w: 886,
            h: 1920,
            workPath: '/girl.work.mp4',
          ),
        );
      tl.clips
        ..add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 6.8,
            offset: 0,
            track: 0,
          ),
        )
        ..add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: 1,
            trimStart: 0,
            trimEnd: 3,
            offset: topAt,
            track: 1,
          ),
        );
    });
    await tick(t, 15);
  }

  /// 預覽畫框（畫布那個 AspectRatio）實際排出來的大小
  Size canvasBox(WidgetTester t) => t.getSize(find.byType(AspectRatio).first);

  double canvasAspect(WidgetTester t) {
    final s = canvasBox(t);
    return s.width / s.height;
  }

  testWidgets('上層直式晚一點開始：停著、播放中、播過再停，框都是橫的、大小不變', (t) async {
    await openTwoTracks(t, topAt: 0.5);
    final before = canvasBox(t);
    expect(
      before.width / before.height,
      closeTo(16 / 9, 0.01),
      reason: '一進來是底層街景的橫式',
    );

    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 36, 33); // 約 1.2 秒：上層那段已經開始播
    expect(isPlaying(), isTrue);
    expect(playheadOf(t), greaterThan(0.6), reason: '要播到上層那段開始之後');
    expect(canvasBox(t), before, reason: '播放中框換成了上層直式的比例');

    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await tick(t, 5);
    expect(isPlaying(), isFalse);
    expect(canvasBox(t), before, reason: '停在上層那段上，框要照舊是橫的');
  });

  testWidgets('兩段都從 0 開始（實機的排法）：一進來就是橫的，合成不另外送比例', (t) async {
    await openTwoTracks(t);
    expect(
      canvasAspect(t),
      closeTo(16 / 9, 0.01),
      reason: '框跟著上層直式走了（匯出跟合成是底層的橫式）',
    );
    expect(comp.buildArgs, isNotEmpty, reason: '合成要組起來');
    expect(
      comp.buildArgs.last['canvasAspect'],
      isNull,
      reason: '底層就是影片：比例交給原生量（送 Dart 算的會多一條黑線）',
    );
  });

  testWidgets('底層直式圖片、上面疊橫式影片：框照圖片，合成也收到圖片的比例', (t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources
        ..add(
          MediaSource(
            path: '/bg.png',
            name: 'bg',
            kind: ClipKind.image,
            duration: 3600,
            w: 1080,
            h: 1920,
          ),
        )
        ..add(
          MediaSource(
            path: '/street.mp4',
            name: 'street',
            kind: ClipKind.video,
            duration: 5,
            w: 1920,
            h: 1080,
            workPath: '/street.work.mp4',
          ),
        );
      tl.clips
        ..add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 5,
            offset: 0,
            track: 0,
          ),
        )
        ..add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: 1,
            trimStart: 0,
            trimEnd: 5,
            offset: 0,
            track: 1,
          ),
        );
    });
    await tick(t, 15);

    expect(
      canvasAspect(t),
      closeTo(1080 / 1920, 0.01),
      reason: '匯出的畫布照最底層的圖片（直式）',
    );
    expect(comp.buildArgs, isNotEmpty, reason: '合成要組起來');
    expect(
      comp.buildArgs.last['canvasAspect'],
      closeTo(1080 / 1920, 1e-6),
      reason: '合成只挑影片當底：不送就照橫式影片組，跟框對不上',
    );
  });
}
