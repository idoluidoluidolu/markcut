// 合成模式下不該多養逐片段播放器；離開編輯器不該把 State 留住。
//
// 1. _ensureCtrlFor 的守門：合成播放器在台上時，復原（_restoreSnapshot
//    對每個片段叫一次）不能為影片片段開 AVPlayer——十段 4K 的專案按一次
//    上一步就是十顆解碼器同時活著（jetsam）。Diag.peak('同時活著的片段
//    播放器') 是那條路唯一的痕跡，這裡盯它。
// 2. VideoEditorScreen.debugTimeline 是靜態閉包、抓著 State：dispose
//    不清的話整個編輯器（拖曳快取 96MB、疊加物快取 32MB、縮圖帶、60 份
//    復原快照）離開後還活到下次再開
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';

Future<void> _tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

void main() {
  const compCh = MethodChannel('markcut/comp');
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
    Diag.playerLayer.value = false;
    Diag.reset();
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
            'duration': 5.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
        case 'position':
          return 0;
        case 'setHiddenImageTracks':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
  });

  /// 兩段影片（不同來源）＋一段配樂：復原時三個片段都會走 _ensureCtrlFor
  void seed(TimelineModel m) {
    for (var i = 0; i < 2; i++) {
      m.sources.add(
        MediaSource(
          path: '/v$i.mp4',
          name: 'v$i',
          kind: ClipKind.video,
          duration: 100,
          workPath: '/v$i.work.mp4',
        ),
      );
      m.clips.add(
        TimelineClip(
          id: m.nextId(),
          sourceIndex: i,
          trimStart: 0,
          trimEnd: 2,
          offset: i * 2.0,
          track: 0,
        ),
      );
    }
    m.sources.add(
      MediaSource(path: '/m.m4a', name: 'm', kind: ClipKind.audio, duration: 30),
    );
    m.clips.add(
      TimelineClip(
        id: m.nextId(),
        sourceIndex: 2,
        trimStart: 0,
        trimEnd: 3,
        offset: 0,
        track: 1,
      ),
    );
  }

  Widget app() => MaterialApp(
    // 按鈕不畫墨水漣漪：--no-test-assets 下 ink_sparkle 的 shader 資產不在
    theme: ThemeData(useMaterial3: true, splashFactory: NoSplash.splashFactory),
    home: const VideoEditorScreen(blank: true),
  );

  testWidgets('合成模式按上一步：一顆逐片段播放器都不開', (t) async {
    await t.pumpWidget(app());
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!(seed);
    await _tick(t, 15);
    expect(builds, 1, reason: '合成播放器要在台上');

    // 一個可以復原的動作：修剪手勢起手就拍快照（onTrimStart→_pushUndo），
    // 直接叫回呼、不用真的拖
    final tlWidget = t.widget<TimelineEditor>(find.byType(TimelineEditor));
    tlWidget.onTrimStart!();
    tlWidget.onTrim(tlWidget.timeline.clips[0].id, 1.0, false);
    tlWidget.onTrimEnd!();
    await _tick(t, 3);

    Diag.reset();
    await t.tap(find.byIcon(Icons.undo));
    await _tick(t, 5);
    expect(
      Diag.report(),
      isNot(contains('同時活著的片段播放器')),
      reason: '復原走 _ensureCtrlFor 三次（兩段影片＋配樂），合成在台上時一顆都不該開',
    );
    await _tick(t, 100);
  });

  testWidgets('離開編輯器：靜態的 debugTimeline 鉤子要清掉（不然整個 State 被留住）', (
    t,
  ) async {
    await t.pumpWidget(app());
    await _tick(t, 5);
    expect(VideoEditorScreen.debugTimeline, isNotNull);
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await _tick(t, 5);
    expect(
      VideoEditorScreen.debugTimeline,
      isNull,
      reason: 'dispose 要把抓著 this 的閉包放掉',
    );
  });

  testWidgets('兩個編輯器先後開：後開的鉤子不會被先開那個的 dispose 清掉', (t) async {
    await t.pumpWidget(app());
    await _tick(t, 5);
    // 換一個新的編輯器實例：舊的 dispose、新的 initState 掛上自己的鉤子
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: NoSplash.splashFactory,
        ),
        home: const VideoEditorScreen(blank: true, key: ValueKey('second')),
      ),
    );
    await _tick(t, 5);
    expect(
      VideoEditorScreen.debugTimeline,
      isNotNull,
      reason: '新實例的鉤子要活著（舊實例只清自己那份）',
    );
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await _tick(t, 5);
    expect(VideoEditorScreen.debugTimeline, isNull);
  });
}
