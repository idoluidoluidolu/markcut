// 守門：選中素材後在畫布上拖曳／捏合，每一格指針事件只重畫預覽層，
// 不整頁重建。
//
// 背景：影片編輯器整頁 setState 一次要重建 ~680 個 element（時間軸
// ~400、控制列／分頁列 ~300），桌機上 15~40ms——手指在動時每格來一次
// 就是使用者說的「圖片素材放大縮小不夠跟手」。修法跟面板滑桿的
// _wmLiveTick 同一條路：手勢中撥 _frameVN 只重建預覽層的
// ValueListenableBuilder，放手才整頁 setState（見 _gestureLiveTick）。
//
// 這裡用 Element.rebuild 的除錯鉤子數「手勢中哪些 widget 被重建」：
// 預覽層外的 TimelineEditor／AppBar 一次都不能重建，預覽層裡的
// CenterGuides 每格都要重建（畫面真的有跟著動）；放手後時間軸要補
// 重建一次（值要落到頁面其他部分）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';
import 'package:markcut/widgets/watermark_layer.dart';

Future<void> _tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

void main() {
  const compCh = MethodChannel('markcut/comp');
  late List<Map<Object?, Object?>> xformCalls;

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
    xformCalls = [];
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
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
      }
      return null;
    });
  });

  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
  });

  /// 影片墊在 5~10 秒；播放頭 0 時畫面上是「同軌（烘進合成）的圖片」
  /// ＋一段文字。捏合圖片會走 setXform（原生跟手那條路要照常每格送）
  late TimelineModel tl;
  void seed(TimelineModel m) {
    tl = m;
    m.sources.add(
      MediaSource(
        path: '/v.mp4',
        name: 'v',
        kind: ClipKind.video,
        duration: 100,
        workPath: '/v.work.mp4',
      ),
    );
    m.clips.add(
      TimelineClip(
        id: m.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 5,
        track: 0,
      ),
    );
    m.sources.add(
      MediaSource(path: '/p.png', name: 'p', kind: ClipKind.image, duration: 3600),
    );
    m.clips.add(
      TimelineClip(
        id: m.nextId(),
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 3,
        offset: 0,
        track: 0,
      ),
    );
    m.sources.add(
      MediaSource(
        path: '',
        name: 't',
        kind: ClipKind.text,
        duration: 3600,
        textStyle: TextMark(text: '你好'),
      ),
    );
    m.clips.add(
      TimelineClip(
        id: m.nextId(),
        sourceIndex: 2,
        trimStart: 0,
        trimEnd: 8,
        offset: 0,
        track: 1,
        px: 0.5,
        py: 0.85,
      ),
    );
  }

  Map<String, int> rebuilt = {};
  void startCounting() {
    rebuilt = {};
    debugOnRebuildDirtyWidget = (e, _) {
      final k = e.widget.runtimeType.toString();
      rebuilt[k] = (rebuilt[k] ?? 0) + 1;
    };
  }

  void stopCounting() => debugOnRebuildDirtyWidget = null;

  int of(String k) => rebuilt[k] ?? 0;

  testWidgets('拖曳／捏合選中的圖片：每格只重畫預覽層，放手才整頁重建', (t) async {
    await t.pumpWidget(
      const MaterialApp(home: VideoEditorScreen(blank: true)),
    );
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!(seed);
    await _tick(t, 15);

    final previewRect = t.getRect(find.byType(AspectRatio).first);
    // 預設浮水印文字蓋在畫布正中央，選取要點上緣才點得到圖片
    await t.tapAt(Offset(previewRect.center.dx, previewRect.top + 24));
    await t.pump();
    final img = tl.clips[1];
    final px0 = img.px, py0 = img.py, s0 = img.scale;
    expect(find.byType(TimelineEditor), findsOneWidget);

    // ---- 單指拖曳 ----
    final c = previewRect.center;
    final g = await t.startGesture(c);
    await t.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(10, 0)); // 越過 6px 起手門檻
    await t.pump(const Duration(milliseconds: 16));
    const moves = 20;
    startCounting();
    for (var i = 0; i < moves; i++) {
      await g.moveBy(const Offset(3, 2));
      await t.pump(const Duration(milliseconds: 16));
    }
    stopCounting();
    expect(img.px, greaterThan(px0), reason: '圖片要真的跟著手指走');
    expect(img.py, greaterThan(py0));
    // 不要求「每格剛好一次」：起手幾格吸在中線上、同一格兩次撥動會
    // 併成一次重建。要的是預覽層在手勢中確實一直在重建
    expect(
      of('CenterGuides'),
      greaterThanOrEqualTo(moves ~/ 2),
      reason: '預覽層在拖曳中要持續重建（畫面跟手）',
    );
    expect(
      of('TimelineEditor'),
      0,
      reason: '拖曳中不能整頁重建：時間軸（~400 個 element）一次都不該重建',
    );
    expect(of('AppBar'), 0, reason: '拖曳中不能整頁重建');
    expect(of('VideoEditorScreen'), 0, reason: '拖曳中不能整頁重建');

    startCounting();
    await g.up();
    await t.pump();
    stopCounting();
    expect(
      of('TimelineEditor'),
      greaterThanOrEqualTo(1),
      reason: '放手要整頁 setState 一次，值才落到頁面其他部分',
    );

    // ---- 雙指捏合（烘進合成的圖片：每格還是要送 setXform）----
    final a = await t.startGesture(c + const Offset(-30, 0));
    final b2 = await t.startGesture(c + const Offset(30, 0));
    await t.pump(const Duration(milliseconds: 20));
    xformCalls.clear();
    startCounting();
    for (var i = 0; i < moves; i++) {
      await a.moveBy(const Offset(-3, 0));
      await b2.moveBy(const Offset(3, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    stopCounting();
    expect(img.scale, greaterThan(s0), reason: '兩指張開＝放大');
    expect(of('CenterGuides'), greaterThanOrEqualTo(moves ~/ 2));
    expect(of('TimelineEditor'), 0, reason: '捏合中不能整頁重建');
    expect(of('VideoEditorScreen'), 0, reason: '捏合中不能整頁重建');
    // 每格送的契約（33ms 真時鐘節流）在 live_xform_baked_image_test；
    // 這裡只守「不整頁重建之後 setXform 照樣有送」
    expect(
      xformCalls,
      isNotEmpty,
      reason: '即時變形（setXform）不走 setState 也要照常送到原生端',
    );

    startCounting();
    await a.up();
    await b2.up();
    await t.pump();
    stopCounting();
    expect(of('TimelineEditor'), greaterThanOrEqualTo(1), reason: '放手補整頁');

    await _tick(t, 100);
  });

  testWidgets('全域浮水印：WatermarkLayer 自己的拖曳也只重畫預覽層', (t) async {
    await t.pumpWidget(
      const MaterialApp(home: VideoEditorScreen(blank: true)),
    );
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!(seed);
    await _tick(t, 15);

    // 沒選任何片段：畫布中央是預設的浮水印文字，拖它走 WatermarkLayer
    // 自己的 onPanUpdate
    final previewRect = t.getRect(find.byType(AspectRatio).first);
    final c = previewRect.center;
    final layer = t.widget<WatermarkLayer>(find.byType(WatermarkLayer).first);
    // 暖身一手：第一次動到疊加物內容時，疊加物同步會把「原生版上屏」
    // 的旗標翻一次（一次性的整頁 setState）；起手拍快照排的存草稿
    //（900ms）＋停手重組合成也各自 setState 一次。這些都跟「每格」無關，
    // 先讓它們跑完，計數的那一手才只剩指針事件本身的影響
    {
      final w0 = await t.startGesture(c);
      await t.pump(const Duration(milliseconds: 16));
      await w0.moveBy(const Offset(12, 0));
      await t.pump(const Duration(milliseconds: 16));
      await w0.moveBy(const Offset(-12, 0));
      await t.pump(const Duration(milliseconds: 16));
      await w0.up();
      await _tick(t, 50);
      // 點到浮水印會切去浮水印分頁；那一頁開著時手勢中會節流地整頁
      // 重建讓面板滑桿跟著動（設計如此），這裡要量的是剪輯分頁的情況
      await t.tap(find.text('剪輯'));
      await _tick(t, 10);
    }
    final tx0 = layer.settings.text.x;
    final g = await t.startGesture(c);
    await t.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(12, 0));
    await t.pump(const Duration(milliseconds: 16));
    const moves = 20;
    startCounting();
    for (var i = 0; i < moves; i++) {
      await g.moveBy(const Offset(3, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    stopCounting();
    expect(layer.settings.text.x, greaterThan(tx0), reason: '文字要跟著走');
    // 最多一次：WatermarkLayer 自己的拖曳被選取路由接手時（浮水印一被
    // 選取，路由層就疊上來搶手勢）它的 onPanCancel 會做一次「放手收尾」。
    // 那是一手結束，不是每格；每格整頁重建的話這裡會是 20
    expect(
      of('VideoEditorScreen'),
      lessThanOrEqualTo(1),
      reason: '拖浮水印中不能每格整頁重建',
    );
    expect(of('CenterGuides'), greaterThanOrEqualTo(moves ~/ 2));

    startCounting();
    await g.up();
    await t.pump();
    stopCounting();
    expect(of('TimelineEditor'), greaterThanOrEqualTo(1), reason: '放手補整頁');
    await _tick(t, 100);
  });
}
