// 迴歸守門：使用者回報「圖片素材放大縮小不夠跟手」。
//
// 根因（見 lib/services/comp_player.dart 的 setXform／
// lib/screens/video_editor_screen.dart 的 _liveXformSync）：烘進合成的
// 圖片/GIF（CompPlayer.bakedImageIds）以前捏合/拖曳完全不會送 liveXform，
// 只能等 350ms 停手後的整份重組——手指在動的時候，原生畫面停在舊位置，
// Flutter 版的選取框先跑走，就是「不夠跟手」。
//
// 治本：_liveXformSync 現在也認烘進合成的圖片片段（跟影片片段走同一條
// setXform 通道，原生端 CILayerSpec 加了 uScale/uPx/uPy 基準、拿掉了
// render 迴圈那句排除 trackID＝Invalid 的判斷——見 AppDelegate.swift）。
// 這裡只測 Dart 這一側的契約：捏合中的確送出 setXform，而且 z/start
// 對得上那個圖片片段。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/widgets/timeline_editor.dart';

Future<void> _tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

void main() {
  const compCh = MethodChannel('markcut/comp');
  late List<Map<Object?, Object?>> xformCalls;
  late List<List<Object?>> visibilityCalls;
  var builds = 0;

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1100, 2200);
    v.devicePixelRatio = 1.0;
    for (final ch in const [
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 測試環境沒有真的原生 UiKitView：合成畫面改走 Texture，
    // 不然那顆平台視圖會把整塊預覽區的點擊吃掉，選不到圖片
    Diag.playerLayer.value = false;
    xformCalls = [];
    visibilityCalls = [];
    builds = 0;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          builds++;
          return <String, dynamic>{
            'textureId': 1,
            'duration': 10.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
        case 'setXform':
          xformCalls.add(Map<Object?, Object?>.from(call.arguments as Map));
          return true;
        case 'setHiddenImageTracks':
          visibilityCalls.add(
            List<Object?>.from((call.arguments as Map)['tracks'] as List),
          );
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
  });

  testWidgets('烘進合成的圖片：捏合中送 setXform（跟手），不用等重組', (t) async {
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
    await _tick(t, 5);

    final debugTimeline = VideoEditorScreen.debugTimeline;
    expect(debugTimeline, isNotNull);
    debugTimeline!((tl) {
      // 影片墊在 5~10 秒——播放頭停在預設的 0，圖片才是「現在畫面上」
      // 唯一點得到的東西，捏合不會誤中影片
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
          offset: 5,
          track: 1,
        ),
      );
      // 圖片軌低於影片（track<=top），且獨立成軌，可即時切可見性。
      tl.sources.add(
        MediaSource(
          path: '/p.png',
          name: 'p',
          kind: ClipKind.image,
          duration: 3600,
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 1,
          trimStart: 0,
          trimEnd: 3,
          offset: 0,
          track: 0,
        ),
      );
    });

    // 等 350ms 併批計時器＋原生端（假的）build 回來，合成播放器就緒
    await _tick(t, 15);

    final initialBuilds = builds;
    final timelineWidget = t.widget<TimelineEditor>(
      find.byType(TimelineEditor),
    );
    timelineWidget.onToggleHidden!(0);
    await _tick(t, 20);
    expect(visibilityCalls.last, [0]);
    expect(
      builds,
      initialBuilds,
      reason: 'hiding an image must not rebuild the player',
    );
    timelineWidget.onToggleHidden!(0);
    await _tick(t, 20);
    expect(visibilityCalls.last, isEmpty);
    expect(
      builds,
      initialBuilds,
      reason: 'showing the image must reuse its native layer',
    );

    final previewRect = t.getRect(find.byType(AspectRatio).first);
    // 預設有一顆置中的浮水印文字（"@我的浮水印"，見
    // WatermarkSettings/TextMark 的預設值），蓋住畫布正中央——選取要
    // 點畫布上緣，不然點到浮水印而不是圖片
    final selectPoint = Offset(previewRect.center.dx, previewRect.top + 24);
    await t.tapAt(selectPoint);
    await t.pump();

    // 再點選取中的圖片開啟面板。透明度要走同一張原生圖層，最後一值
    // 必須送到，不能等整份合成重建才出現。
    int? imageId;
    debugTimeline((tl) => imageId = tl.clips.last.id);
    t.widget<TimelineEditor>(find.byType(TimelineEditor)).onTapSelectedClip!(
      imageId!,
    );
    await _tick(t, 10);
    expect(find.text('透明度'), findsOneWidget);
    final opacitySlider = find.byType(Slider).last;
    final slider = t.widget<Slider>(opacitySlider);
    slider.onChangeStart!(slider.value);
    slider.onChanged!(0.5);
    await _tick(t, 2);
    expect(xformCalls.last['opacity'], 0.5);
    slider.onChanged!(0.94);
    await _tick(t, 2);
    expect(xformCalls.last['opacity'], 0.94);
    CompPlayer.onCompVisible?.call();
    await t.pump();
    expect(xformCalls.last['opacity'], 0.94);
    // 跨過舊的 1.7 秒清理計時器，不能抹掉正在調整的覆寫。
    final callsBeforeHold = xformCalls.length;
    await _tick(t, 50);
    expect(
      xformCalls.skip(callsBeforeHold).where((c) => c['clear'] == true),
      isEmpty,
    );
    slider.onChangeEnd!(0.94);
    Navigator.of(t.element(opacitySlider)).pop();
    await _tick(t, 10);
    xformCalls.clear();

    // 兩指捏合放大：東西一旦選上了，「選取路由」疊在最上層、整塊預覽區
    // 的拖曳／捏合都只作用在被選中的素材上（見 video_editor_screen.dart
    // 「選取路由」那段），這裡改回畫面正中央捏合沒問題
    final c = previewRect.center;
    final a = await t.startGesture(c + const Offset(-30, 0));
    final b2 = await t.startGesture(c + const Offset(30, 0));
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(-6, 0));
      await b2.moveBy(const Offset(6, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b2.up();
    await t.pump();

    expect(
      xformCalls,
      isNotEmpty,
      reason: '圖片素材捏合要立刻送 setXform，不能只等 350ms 後的整份重組',
    );
    final last = xformCalls.last;
    expect(last['z'], 0, reason: 'z 要對到圖片片段的軌道');
    expect(
      (last['start'] as num).toDouble(),
      closeTo(0.0, 0.02),
      reason: 'start 要對到圖片片段的 offset，原生端靠這兩個值認層',
    );
    expect(
      (last['scale'] as num).toDouble(),
      greaterThan(1.0),
      reason: '兩指張開＝放大',
    );

    // 放手排的計時器（350ms 重組、存草稿）要跑掉，測試才乾淨收尾
    await _tick(t, 100);
  });

  testWidgets('沒烘進合成的圖片（壓在影片之上）：捏合不送 setXform，SDR 那條路不變', (t) async {
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
    await _tick(t, 5);

    final debugTimeline = VideoEditorScreen.debugTimeline;
    expect(debugTimeline, isNotNull);
    debugTimeline!((tl) {
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
          offset: 5,
          track: 0,
        ),
      );
      // 圖片在比影片更高的軌（track > top）＝壓在影片之上，
      // Flutter 自己畫、不烘進合成——見 CompPlayer.bakedImageIds
      tl.sources.add(
        MediaSource(
          path: '/p.png',
          name: 'p',
          kind: ClipKind.image,
          duration: 3600,
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 1,
          trimStart: 0,
          trimEnd: 3,
          offset: 0,
          track: 1,
        ),
      );
    });

    await _tick(t, 15);

    final previewRect = t.getRect(find.byType(AspectRatio).first);
    final selectPoint = Offset(previewRect.center.dx, previewRect.top + 24);
    await t.tapAt(selectPoint);
    await t.pump();

    final c = previewRect.center;
    final a = await t.startGesture(c + const Offset(-30, 0));
    final b2 = await t.startGesture(c + const Offset(30, 0));
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(-6, 0));
      await b2.moveBy(const Offset(6, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b2.up();
    await t.pump();

    expect(
      xformCalls,
      isEmpty,
      reason: '沒烘進合成的圖片本來就是 Flutter 即時畫，不該多送 setXform',
    );

    await _tick(t, 100);
  });
}
