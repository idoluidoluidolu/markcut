// 影片編輯器「一次整頁 setState 要幾毫秒」的量尺。預設略過，不進一般測試。
//
// 跑法（PowerShell）：
//   $env:MARKCUT_BENCH='1'; flutter test --no-pub test/perf/editor_rebuild_bench_test.dart
// 跑法（bash）：
//   MARKCUT_BENCH=1 flutter test --no-pub test/perf/editor_rebuild_bench_test.dart
//
// 量三樣：閒置 pump（底噪）、空的 setState(() {})（整頁 build 的成本）、
// 以及真手勢——選中圖片後單指拖曳／雙指捏合，每一格指針事件走真的
// 選取路由與捏合 Listener。桌機數字不是 iPhone 數字，看的是「每格
// 幾毫秒」對 16.7ms 預算的比例、以及改前改後的差。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';
import 'package:markcut/widgets/watermark_panel.dart';

final _bench = Platform.environment['MARKCUT_BENCH'] == '1';

Future<void> _tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

String _stats(String name, List<int> us) {
  final s = List.of(us)..sort();
  final med = s[s.length ~/ 2];
  final p90 = s[(s.length * 0.9).floor().clamp(0, s.length - 1)];
  final avg = s.reduce((a, b) => a + b) / s.length;
  String ms(num v) => (v / 1000).toStringAsFixed(2);
  return '${name.padRight(30)} med ${ms(med)}ms  p90 ${ms(p90)}ms  '
      'avg ${ms(avg)}ms  min ${ms(s.first)}ms  max ${ms(s.last)}ms  (n=${s.length})';
}

void main() {
  const compCh = MethodChannel('markcut/comp');

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
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
  });

  /// 一支影片＋一張同軌圖片（烘進合成）＋一張上層圖片＋一段文字：
  /// 接近使用者真實專案的圖層數，時間軸也有東西可以排
  void seed(TimelineModel tl) {
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
    tl.sources.add(
      MediaSource(path: '/p.png', name: 'p', kind: ClipKind.image, duration: 3600),
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
    tl.sources.add(
      MediaSource(path: '/q.png', name: 'q', kind: ClipKind.image, duration: 3600),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: 2,
        trimStart: 0,
        trimEnd: 8,
        offset: 1,
        track: 1,
      ),
    );
    tl.sources.add(
      MediaSource(
        path: '',
        name: 't',
        kind: ClipKind.text,
        duration: 3600,
        textStyle: TextMark(text: '你好'),
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: 3,
        trimStart: 0,
        trimEnd: 8,
        offset: 0,
        track: 2,
      ),
    );
  }

  testWidgets('整頁 setState 與每格指針事件的成本', (t) async {
    await t.pumpWidget(
      const MaterialApp(home: VideoEditorScreen(blank: true)),
    );
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!(seed);
    await _tick(t, 15);

    final rows = <String>[];
    const n = 40;

    // 底噪：什麼都沒髒的 pump
    final idle = <int>[];
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      await t.pump();
      idle.add(sw.elapsedMicroseconds);
    }
    rows.add(_stats('idle pump', idle));

    // 空的整頁 setState
    final state = t.state(find.byType(VideoEditorScreen));
    final full = <int>[];
    // 只量 build 階段（不含 layout/paint）：BuildOwner 直接 buildScope
    final buildOnly = <int>[];
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      // ignore: invalid_use_of_protected_member
      state.setState(() {});
      await t.pump();
      full.add(sw.elapsedMicroseconds);
    }
    rows.add(_stats('bare setState + pump', full));
    for (var i = 0; i < n; i++) {
      // ignore: invalid_use_of_protected_member
      state.setState(() {});
      final sw = Stopwatch()..start();
      t.binding.buildOwner!.buildScope(t.binding.rootElement!);
      buildOnly.add(sw.elapsedMicroseconds);
      await t.pump();
    }
    rows.add(_stats('build phase only (buildScope)', buildOnly));

    // 分階段：build / layout / compositing bits / paint / 剩下的 pump
    final ph = <String, List<int>>{
      'build': [],
      'layout': [],
      'compositing': [],
      'paint': [],
      'rest of pump': [],
    };
    final needsLayout = <String, int>{};
    final needsPaint = <String, int>{};
    void census(RenderObject r, Map<String, int> lay, Map<String, int> pnt) {
      if (r.debugNeedsLayout) {
        final k = r.runtimeType.toString();
        lay[k] = (lay[k] ?? 0) + 1;
      }
      if (r.debugNeedsPaint) {
        final k = r.runtimeType.toString();
        pnt[k] = (pnt[k] ?? 0) + 1;
      }
      r.visitChildren((c) => census(c, lay, pnt));
    }

    final po = t.binding.rootPipelineOwner;
    for (var i = 0; i < n; i++) {
      // ignore: invalid_use_of_protected_member
      state.setState(() {});
      var sw = Stopwatch()..start();
      t.binding.buildOwner!.buildScope(t.binding.rootElement!);
      ph['build']!.add(sw.elapsedMicroseconds);
      if (i == 0) census(t.binding.renderViews.first,needsLayout, needsPaint);
      sw = Stopwatch()..start();
      po.flushLayout();
      ph['layout']!.add(sw.elapsedMicroseconds);
      sw = Stopwatch()..start();
      po.flushCompositingBits();
      ph['compositing']!.add(sw.elapsedMicroseconds);
      if (i == 0) census(t.binding.renderViews.first,<String, int>{}, needsPaint);
      sw = Stopwatch()..start();
      po.flushPaint();
      ph['paint']!.add(sw.elapsedMicroseconds);
      sw = Stopwatch()..start();
      await t.pump();
      ph['rest of pump']!.add(sw.elapsedMicroseconds);
    }
    for (final e in ph.entries) {
      rows.add(_stats('phase ${e.key}', e.value));
    }
    String top(Map<String, int> m) {
      final es = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      return es.take(25).map((e) => '${e.key}x${e.value}').join(', ');
    }
    rows.add('  needsLayout after build: ${top(needsLayout)}');
    rows.add('  needsPaint after layout: ${top(needsPaint)}');

    // setState 呼叫本身（override 裡的 _ovStateChanged／_liveXformSync）
    final ssOnly = <int>[];
    for (var i = 0; i < n; i++) {
      final sw = Stopwatch()..start();
      // ignore: invalid_use_of_protected_member
      state.setState(() {});
      ssOnly.add(sw.elapsedMicroseconds);
      await t.pump();
    }
    rows.add(_stats('setState call only', ssOnly));

    // 一格重建了哪些 widget（型別計數）：Element.rebuild 的除錯鉤子
    final rebuilt = <String, int>{};
    var rebuiltTotal = 0;
    debugOnRebuildDirtyWidget = (e, _) {
      rebuiltTotal++;
      final k = e.widget.runtimeType.toString();
      rebuilt[k] = (rebuilt[k] ?? 0) + 1;
    };
    // ignore: invalid_use_of_protected_member
    state.setState(() {});
    await t.pump();
    debugOnRebuildDirtyWidget = null;
    rows.add('  elements rebuilt per bare setState frame: $rebuiltTotal');
    rows.add('  by widget type: ${top(rebuilt)}');

    // 各子樹的 element 數（重建量的來源）
    int countEl(Element e) {
      var k = 1;
      e.visitChildren((c) => k += countEl(c));
      return k;
    }

    final scaffoldEl = find.byType(Scaffold).evaluate().first;
    rows.add('  elements under Scaffold: ${countEl(scaffoldEl)}');
    rows.add(
      '  elements under AppBar: ${countEl(find.byType(AppBar).evaluate().first)}',
    );
    final bodyCol = find
        .descendant(of: find.byType(Scaffold), matching: find.byType(Column))
        .evaluate()
        .first;
    var idx = 0;
    bodyCol.visitChildren((c) {
      rows.add(
        '  body Column child #$idx (${c.widget.runtimeType}): ${countEl(c)}',
      );
      idx++;
    });
    rows.add(
      '    preview ValueListenableBuilder subtree: '
      '${countEl(find.byWidgetPredicate((w) => w is ValueListenableBuilder<double>).evaluate().first)}',
    );
    rows.add(
      '    TimelineEditor subtree: '
      '${countEl(find.byType(TimelineEditor).evaluate().first)}',
    );
    rows.add(
      '    TabBar subtree: ${countEl(find.byType(TabBar).evaluate().first)}',
    );
    rows.add(
      '    WatermarkPanel built? ${find.byType(WatermarkPanel).evaluate().isNotEmpty}',
    );

    // 選中「上層」圖片（Flutter 自己畫的那張，播放頭 0 時它在畫面上）
    final previewRect = t.getRect(find.byType(AspectRatio).first);
    final selectPoint = Offset(previewRect.center.dx, previewRect.top + 24);
    await t.tapAt(selectPoint);
    await t.pump();

    // 單指拖曳：每格一個 move 事件經過選取路由
    final c = previewRect.center;
    {
      final g = await t.startGesture(c);
      await t.pump(const Duration(milliseconds: 16));
      await g.moveBy(const Offset(10, 0)); // 越過 6px 門檻
      await t.pump(const Duration(milliseconds: 16));
      final drag = <int>[];
      for (var i = 0; i < n; i++) {
        final sw = Stopwatch()..start();
        await g.moveBy(Offset(i.isEven ? 3 : -3, 2));
        await t.pump(const Duration(milliseconds: 16));
        drag.add(sw.elapsedMicroseconds);
      }
      rows.add(_stats('1-finger drag move + pump', drag));
      await g.up();
      await t.pump();
    }

    // 雙指捏合：每格兩個 move 事件經過捏合 Listener
    {
      final a = await t.startGesture(c + const Offset(-30, 0));
      final b2 = await t.startGesture(c + const Offset(30, 0));
      await t.pump(const Duration(milliseconds: 20));
      final pinch = <int>[];
      for (var i = 0; i < n; i++) {
        final d = i < n / 2 ? 2.0 : -2.0;
        final sw = Stopwatch()..start();
        await a.moveBy(Offset(-d, 0));
        await b2.moveBy(Offset(d, 0));
        await t.pump(const Duration(milliseconds: 16));
        pinch.add(sw.elapsedMicroseconds);
      }
      rows.add(_stats('2-finger pinch (2 moves) + pump', pinch));
      await a.up();
      await b2.up();
      await t.pump();
    }

    // ignore: avoid_print
    print('\n=== editor rebuild bench ===\n${rows.join('\n')}\n');
    await _tick(t, 100);
  }, skip: !_bench);
}
