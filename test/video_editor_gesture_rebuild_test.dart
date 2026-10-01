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
import 'package:markcut/services/media_geometry.dart';
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
      MediaSource(
        path: '/p.png',
        name: 'p',
        kind: ClipKind.image,
        duration: 3600,
      ),
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

  testWidgets(
    'speed supports precise increments, presets and draft restoration',
    (t) async {
      await t.pumpWidget(
        const MaterialApp(home: VideoEditorScreen(blank: true)),
      );
      await _tick(t, 5);
      VideoEditorScreen.debugTimeline!(seed);
      await _tick(t, 15);
      t
          .widget<TimelineEditor>(find.byType(TimelineEditor))
          .onSelect(tl.clips[0].id);
      await t.pump();
      await t.tap(find.byTooltip('片段速度'));
      await _tick(t, 10);
      for (final rate in [1.1, 1.2, 1.25]) {
        await t.tap(find.byKey(ValueKey('clip-speed-preset-$rate')));
        await t.pump();
        expect(tl.clips[0].speed, rate);
        expect(tl.clips[0].length, closeTo(5 / rate, 1e-9));
      }
      await t.tap(find.byKey(const ValueKey('clip-speed-increase')));
      await t.pump();
      expect(tl.clips[0].speed, 1.26);
      await t.tap(find.byKey(const ValueKey('clip-speed-decrease')));
      await t.pump();
      expect(tl.clips[0].speed, 1.25);
      final slider = t.widget<Slider>(
        find.byKey(const ValueKey('clip-speed-slider')),
      );
      slider.onChanged!(kSpeedStops.indexOf(1.01).toDouble());
      await t.pump();
      expect(tl.clips[0].speed, 1.01);
      expect(TimelineClip.fromJson(tl.clips[0].toJson()).speed, 1.01);
      expect(t.takeException(), isNull);
      Navigator.of(
        t.element(find.byKey(const ValueKey('clip-speed-slider'))),
      ).pop();
      await _tick(t, 100);
    },
  );

  testWidgets(
    'text material editor shows multiline content and alignment with keyboard open',
    (t) async {
      t.view.physicalSize = const Size(390, 844);
      addTearDown(() => t.view.physicalSize = const Size(1100, 2200));
      await t.pumpWidget(
        const MaterialApp(home: VideoEditorScreen(blank: true)),
      );
      await _tick(t, 5);
      VideoEditorScreen.debugTimeline!((m) {
        seed(m);
        m.sources[2].name = 'First line\nSecond line';
        m.sources[2].textStyle!.text = m.sources[2].name;
      });
      await _tick(t, 15);
      final timeline = t.widget<TimelineEditor>(find.byType(TimelineEditor));
      timeline.onTapSelectedClip!(tl.clips[2].id);
      await _tick(t, 15);
      final field = find.byKey(const ValueKey('clip-text-content'));
      expect(t.widget<TextField>(field).minLines, 3);
      expect(
        t.widget<TextField>(field).controller!.text,
        'First line\nSecond line',
      );
      await t.tap(find.text('靠右'));
      await t.pump();
      expect(tl.sources[2].textStyle!.alignment, TextAlign.right);
      expect(t.widget<TextField>(field).textAlign, TextAlign.right);
      await t.enterText(field, 'First line\nSecond line\nThird line');
      t.view.viewInsets = const FakeViewPadding(bottom: 300);
      await _tick(t, 10);
      final canvas = t.getRect(find.byType(AspectRatio).first);
      final sheet = t.getRect(find.byType(BottomSheet));
      expect(canvas.height, greaterThan(80));
      expect(
        canvas.bottom,
        lessThanOrEqualTo(sheet.top),
        reason: 'typing must leave the whole live preview above the sheet',
      );
      expect(t.getRect(field).bottom, lessThanOrEqualTo(844 - 300));
      expect(t.getRect(field).height, greaterThanOrEqualTo(70));
      expect(t.takeException(), isNull);
      t.view.resetViewInsets();
      Navigator.of(t.element(field)).pop();
      await _tick(t, 100);
    },
  );

  for (final dimensions in [(390.0, 844.0, 346.0), (375.0, 667.0, 300.0)]) {
    testWidgets(
      'portrait preview and Done stay visible while typing $dimensions',
      (t) async {
        final (width, height, keyboard) = dimensions;
        t.view.physicalSize = Size(width, height);
        t.view.padding = const FakeViewPadding(top: 44, bottom: 34);
        t.view.viewPadding = const FakeViewPadding(top: 44, bottom: 34);
        addTearDown(() {
          t.view.physicalSize = const Size(1100, 2200);
          t.view.resetViewInsets();
          t.view.resetPadding();
          t.view.resetViewPadding();
        });
        await t.pumpWidget(
          const MaterialApp(home: VideoEditorScreen(blank: true)),
        );
        await _tick(t, 5);
        VideoEditorScreen.debugTimeline!((m) {
          seed(m);
          m.sources[0] = MediaSource.fromJson({
            ...m.sources[0].toJson(),
            'w': 1080,
            'h': 1920,
          });
        });
        await _tick(t, 15);
        t
            .widget<TimelineEditor>(find.byType(TimelineEditor))
            .onTapSelectedClip!(tl.clips[2].id);
        await _tick(t, 15);
        final field = find.byKey(const ValueKey('clip-text-content'));
        await t.enterText(
          field,
          List.generate(8, (i) => '第 $i 行文字').join('\n'),
        );
        t.view.viewInsets = FakeViewPadding(bottom: keyboard);
        t.view.padding = const FakeViewPadding(top: 44);
        await _tick(t, 15);
        final canvas = t.getRect(find.byType(AspectRatio).first);
        final sheet = t.getRect(find.byType(BottomSheet));
        expect(canvas.height, greaterThan(60));
        expect(canvas.bottom, lessThanOrEqualTo(sheet.top));
        expect(t.getRect(field).bottom, lessThanOrEqualTo(height - keyboard));
        final done = find.byKey(const ValueKey('clip-text-done'));
        expect(done.hitTestable(), findsOneWidget);
        final scroll = find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(SingleChildScrollView),
            )
            .first;
        t
            .state<ScrollableState>(
              find
                  .descendant(of: scroll, matching: find.byType(Scrollable))
                  .first,
            )
            .position
            .jumpTo(250);
        await t.pump();
        expect(
          done.hitTestable(),
          findsOneWidget,
          reason: 'Done must not scroll out with styling controls',
        );
        await t.tap(done);
        t.view.resetViewInsets();
        await _tick(t, 100);
        expect(find.byType(BottomSheet), findsNothing);
        expect(tl.sources[2].textStyle!.text.split('\n'), hasLength(8));
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets('dragging a cropped image does not clamp its original center', (
    t,
  ) async {
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!((m) {
      seed(m);
      final c = m.clips[1];
      c.scale = 10;
      c.cropL = .8;
      c.cropT = .8;
      c.cropW = .1;
      c.cropH = .1;
      placeMediaVisibleCenter(
        c,
        m.sources[1].aspect,
        m.sources[0].aspect,
        const Offset(.2, .2),
      );
    });
    await _tick(t, 15);
    final timeline = t.widget<TimelineEditor>(find.byType(TimelineEditor));
    timeline.onSelect(tl.clips[1].id);
    await t.pump();
    final r = t.getRect(find.byType(AspectRatio).first);
    final g = await t.startGesture(
      r.topLeft + Offset(r.width * .2, r.height * .2),
    );
    await g.moveBy(const Offset(10, 10));
    await t.pump();
    for (var i = 0; i < 30; i++) {
      await g.moveBy(Offset(r.width * .01, r.height * .01));
      await t.pump(const Duration(milliseconds: 16));
    }
    final visible = mediaVisibleCenter(
      tl.clips[1],
      tl.sources[1].aspect,
      tl.sources[0].aspect,
    );
    expect(visible.dx, closeTo(.5, .04));
    expect(visible.dy, closeTo(.5, .04));
    expect(tl.clips[1].px, lessThan(0));
    await g.up();
    await _tick(t, 100);
  });

  testWidgets('size slider keeps the cropped visible center at high zoom', (
    t,
  ) async {
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!((m) {
      seed(m);
      final c = m.clips[1];
      c.cropL = .8;
      c.cropT = .7;
      c.cropW = .1;
      c.cropH = .2;
      c.rotation = 37;
      c.mirror = true;
      placeMediaVisibleCenter(
        c,
        m.sources[1].aspect,
        m.sources[0].aspect,
        const Offset(.5, .5),
      );
    });
    await _tick(t, 15);
    t.widget<TimelineEditor>(find.byType(TimelineEditor)).onTapSelectedClip!(
      tl.clips[1].id,
    );
    await _tick(t, 15);
    final sliderFinder = find
        .descendant(of: find.byType(BottomSheet), matching: find.byType(Slider))
        .first;
    t.widget<Slider>(sliderFinder).onChanged!(1);
    await t.pump();
    expect(tl.clips[1].scale, kMaxMediaScale);
    final center = mediaVisibleCenter(
      tl.clips[1],
      tl.sources[1].aspect,
      tl.sources[0].aspect,
    );
    expect(center.dx, closeTo(.5, 1e-9));
    expect(center.dy, closeTo(.5, 1e-9));
    Navigator.of(t.element(sliderFinder)).pop();
    await _tick(t, 100);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'media pinch passes the old 3x ceiling and round-trips in a draft',
    (t) async {
      await t.pumpWidget(
        const MaterialApp(home: VideoEditorScreen(blank: true)),
      );
      await _tick(t, 5);
      VideoEditorScreen.debugTimeline!((m) {
        seed(m);
        m.clips[1].scale = 2.9;
      });
      await _tick(t, 15);
      t
          .widget<TimelineEditor>(find.byType(TimelineEditor))
          .onSelect(tl.clips[1].id);
      await t.pump();
      final c = t.getRect(find.byType(AspectRatio).first).center;
      final a = await t.startGesture(c + const Offset(-15, 0));
      final b = await t.startGesture(c + const Offset(15, 0));
      await a.moveBy(const Offset(-105, 0));
      await b.moveBy(const Offset(105, 0));
      await t.pump(const Duration(milliseconds: 40));
      expect(tl.clips[1].scale, greaterThan(20));
      expect(tl.clips[1].scale, lessThanOrEqualTo(kMaxMediaScale));
      expect(
        TimelineClip.fromJson(tl.clips[1].toJson()).scale,
        tl.clips[1].scale,
      );
      await a.up();
      await b.up();
      await _tick(t, 100);
    },
  );

  testWidgets(
    'selection updates locally without invalidating project content',
    (t) async {
      await t.pumpWidget(
        const MaterialApp(home: VideoEditorScreen(blank: true)),
      );
      await _tick(t, 5);
      VideoEditorScreen.debugTimeline!(seed);
      await _tick(t, 15);
      final before = t.widget<TimelineEditor>(find.byType(TimelineEditor));
      startCounting();
      before.onSelect(tl.clips[1].id);
      await t.pump();
      stopCounting();
      final after = t.widget<TimelineEditor>(find.byType(TimelineEditor));
      expect(after.selectedId, tl.clips[1].id);
      expect(after.contentVersion, before.contentVersion);
      expect(of('VideoEditorScreen'), 0);
      expect(of('AppBar'), 0);
      expect(of('TabBar'), 0);
      expect(of('TimelineEditor'), greaterThan(0));
      await t.pumpWidget(const SizedBox());
      await _tick(t, 5);
    },
  );

  testWidgets('拖曳／捏合選中的圖片：每格只重畫預覽層，放手才整頁重建', (t) async {
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
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
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
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
