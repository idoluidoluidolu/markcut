import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/media_prep.dart';

import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const comp = MethodChannel('markcut/comp');
  const frames = MethodChannel('markcut/frames');
  final landings = <Completer<bool>>[];
  final seeks = <Map<Object?, Object?>>[];
  var nativeMs = 0;
  var builds = 0;
  var nativeScrub = false;
  final presentations = <Map<Object?, Object?>>[];
  var returnFrames = true;
  var detailedFrameReply = false;
  double? actualFrameTime;
  final frameRequests = <Map<Object?, Object?>>[];
  Completer<Object?>? heldFrame;
  late Uint8List frameBytes;
  Timer? clock;

  setUp(() {
    bigPhoneView(binding);
    mockEditorPlugins(binding);
    SharedPreferences.setMockInitialValues({});
    Diag.reset();
    Diag.playerLayer.value = false;
    Diag.scrubPrefetch.value = true;
    CompPlayer.debugHdrProbe = (_) async => false;
    landings.clear();
    seeks.clear();
    nativeMs = 0;
    builds = 0;
    nativeScrub = false;
    presentations.clear();
    returnFrames = true;
    detailedFrameReply = false;
    actualFrameTime = null;
    frameRequests.clear();
    heldFrame = null;
    frameBytes = solidPng(20, 100, 220);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(frames, (
      call,
    ) async {
      if (call.method != 'frameAt') return null;
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      if (args['detailed'] == true) {
        frameRequests.add(args);
        final pending = heldFrame;
        heldFrame = null;
        if (pending != null) return await pending.future;
        if (!returnFrames) return null;
        if (detailedFrameReply) {
          return {'bytes': frameBytes, 'actualSeconds': actualFrameTime};
        }
      }
      return returnFrames ? frameBytes : null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(comp, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          builds++;
          return {
            'textureId': builds,
            'duration': 8.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
            'nativeScrub': nativeScrub,
          };
        case 'position':
          return nativeMs;
        case 'seek':
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          seeks.add(args);
          if (args['awaitCompletion'] == true) {
            final landing = Completer<bool>();
            landings.add(landing);
            final ok = await landing.future;
            if (ok) nativeMs = ((args['sec'] as num) * 1000).round();
            return ok;
          }
          nativeMs = ((args['sec'] as num) * 1000).round();
          return null;
        case 'play':
          clock?.cancel();
          clock = Timer.periodic(const Duration(milliseconds: 33), (_) {
            nativeMs += 33;
          });
          return 'ready';
        case 'scrub':
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          presentations.add(args);
          final at = (args['sec'] as num).toDouble();
          if (args['exact'] == true) {
            final landing = Completer<bool>();
            landings.add(landing);
            if (!await landing.future) return {'displayed': false};
          }
          nativeMs = (at * 1000).round();
          return {'displayed': true, 'actualSeconds': at, 'cacheHit': true};
        case 'pause':
        case 'dispose':
          clock?.cancel();
          clock = null;
          return null;
      }
      return null;
    });
  });

  tearDown(() {
    clock?.cancel();
    clock = null;
    CompPlayer.debugHdrProbe = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(comp, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(frames, null);
    for (final landing in landings) {
      if (!landing.isCompleted) landing.complete(false);
    }
  });

  Future<void> open(WidgetTester t, {bool raw = true}) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(
          path: '/raw.mp4',
          name: 'raw',
          kind: ClipKind.video,
          duration: 8,
          workPath: raw ? null : '/work.mp4',
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 8,
          offset: 0,
          track: 0,
        ),
      );
    });
    await tick(t, 20);
    await waitUntil(t, () => builds > 0, maxMs: 3000);
    seeks.clear();
  }

  Finder cache() => find.byWidgetPredicate(
    (w) => w is Image && w.key.toString().contains('scrub-cache-'),
  );

  Future<void> scrub(WidgetTester t, double at) async {
    editorOf(t).onSeek(at);
    await tick(t, 2, 30);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(editorApp(const SizedBox()));
    for (final landing in landings) {
      if (!landing.isCompleted) landing.complete(false);
    }
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  }

  for (final raw in [true, false]) {
    testWidgets('原生合成拖曳 ${raw ? '原檔' : '代理'}不經 JPEG，收尾等真正呈現', (t) async {
      nativeScrub = true;
      await open(t, raw: raw);
      frameRequests.clear();
      await scrub(t, 1);
      expect(presentations, isNotEmpty);
      expect(presentations.first['sec'], 1);
      expect(presentations.first['exact'], false);
      expect(presentations.first['toleranceMs'], raw ? 150 : 0);
      expect(frameRequests, isEmpty);
      expect(cache(), findsNothing);
      expect(seeks, isEmpty, reason: '原生 scrub 已負責 chase，不另排第二次 seek');
      await tick(t, 8);
      expect(landings.length, 1);
      expect(presentations.last['exact'], true);
      expect(presentations.last['toleranceMs'], 0);
      landings.single.complete(true);
      await tick(t, 3);
      expect(frameRequests, isEmpty);
      expect(seeks, isEmpty);
      await close(t);
    });
  }

  testWidgets('原生精準呈現舊回覆不結束新拖曳或覆蓋新播放', (t) async {
    nativeScrub = true;
    await open(t);
    await scrub(t, 1);
    await tick(t, 8);
    expect(landings.length, 1);
    await scrub(t, 2);
    landings.first.complete(false);
    await tick(t, 8);
    expect(landings.length, 2);
    expect(presentations.last['sec'], 2);
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 7, 33);
    expect(isPlaying(), true);
    landings.last.complete(false);
    await tick(t, 3);
    expect(isPlaying(), true);
    await close(t);
  });

  testWidgets('全螢幕進度條共用拖曳路徑，不在每次變更重複精準 seek', (t) async {
    nativeScrub = true;
    await open(t);
    await t.tap(find.byIcon(Icons.fullscreen));
    await tick(t, 2);
    final slider = t.widget<Slider>(find.byType(Slider));
    slider.onChanged!(1);
    await t.pump(const Duration(milliseconds: 50));
    expect(presentations.length, 1);
    expect(presentations.single['exact'], false);
    expect(seeks, isEmpty);
    await tick(t, 8);
    expect(landings.length, 1);
    landings.single.complete(true);
    await tick(t, 2);
    await close(t);
  });

  testWidgets('放手後精準定位未完成，快取不撤掉；完成才露出影片', (t) async {
    await open(t);
    await scrub(t, 1);
    expect(cache(), findsOneWidget);
    await tick(t, 8, 40);
    expect(landings.length, 1);
    expect(cache(), findsOneWidget);
    expect(seeks.last['exact'], true);
    expect(seeks.last['toleranceMs'], 0);
    landings.single.complete(true);
    await tick(t, 2);
    expect(cache(), findsNothing);
    await close(t);
  });

  testWidgets('舊精準回覆不能撤掉新手勢的快取，即使再次停在同位置', (t) async {
    await open(t);
    await scrub(t, 1);
    await tick(t, 8);
    expect(landings.length, 1);
    await scrub(t, 1);
    landings.first.complete(true);
    await t.pump();
    expect(cache(), findsOneWidget);
    await tick(t, 8);
    expect(landings.length, 2);
    landings.last.complete(true);
    await tick(t, 2);
    expect(cache(), findsNothing);
    await close(t);
  });

  testWidgets('等待精準定位時播放，舊回覆不重開拖曳或停止新播放', (t) async {
    await open(t);
    await scrub(t, 1);
    await tick(t, 8);
    expect(landings.length, 1);
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 7, 33);
    expect(isPlaying(), isTrue);
    expect(cache(), findsNothing);
    landings.single.complete(false);
    await tick(t, 3);
    expect(isPlaying(), isTrue);
    expect(cache(), findsNothing);
    await close(t);
  });

  testWidgets('離開頁面後精準完成不碰已釋放的狀態', (t) async {
    await open(t);
    await scrub(t, 1);
    await tick(t, 8);
    expect(landings.length, 1);
    await t.pumpWidget(editorApp(const SizedBox()));
    landings.single.complete(true);
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('新拖曳打斷對齊動畫後，實際時間軸捲動仍更新播放頭', (t) async {
    await open(t);
    await scrub(t, 1);
    // 220ms 的收尾開始，但 90ms 對齊動畫尚未結束。
    await t.pump(const Duration(milliseconds: 170));
    expect(landings.length, 1);
    editorOf(t).onSeek(2);
    await t.pump(const Duration(milliseconds: 100));
    final timeline = editorOf(t);
    timeline.scrollController.jumpTo(3 * timeline.pxPerSec);
    await t.pump();
    expect(playheadOf(t), closeTo(3, 0.01));
    await close(t);
  });

  testWidgets('定位被打斷只重試一次，失敗後新手勢仍可恢復', (t) async {
    await open(t);
    await scrub(t, 1);
    await tick(t, 8);
    landings.single.complete(false);
    await tick(t, 4);
    expect(landings.length, 2);
    expect(cache(), findsOneWidget);
    landings.last.complete(false);
    await tick(t, 30);
    expect(landings.length, 2, reason: '不能在失敗後無限重送 seek');
    expect(cache(), findsOneWidget, reason: '放手定位失敗仍保留最後畫面');
    expect(
      MediaPrep.debugScheduling.interactive,
      false,
      reason: '已放手的失敗定位不能永久暫停背景準備',
    );
    await scrub(t, 1);
    expect(
      MediaPrep.debugScheduling.interactive,
      true,
      reason: '新手勢必須重新取得前景優先權',
    );
    await tick(t, 8);
    expect(landings.length, 3);
    landings.last.complete(true);
    await tick(t, 2);
    expect(cache(), findsNothing);
    await close(t);
  });

  testWidgets('定位兩次失敗後，新合成可重新精準落地並撤掉保留畫面', (t) async {
    await open(t);
    await scrub(t, 1);
    await tick(t, 8);
    landings.single.complete(false);
    await tick(t, 4);
    landings.last.complete(false);
    await tick(t, 30);
    expect(MediaPrep.debugScheduling.interactive, false);
    expect(cache(), findsOneWidget);
    final previousBuilds = builds;
    VideoEditorScreen.debugTimeline!((tl) => tl.clips.first.trimEnd = 7.5);
    await tick(t, 20);
    await waitUntil(t, () => builds > previousBuilds, maxMs: 3000);
    await tick(t, 4);
    expect(landings.length, 3);
    landings.last.complete(true);
    await tick(t, 3);
    expect(cache(), findsNothing);
    await close(t);
  });

  for (final landed in [true, false]) {
    testWidgets('播放前遠距定位${landed ? '成功才起播' : '失敗不假裝在播放'}', (t) async {
      await open(t, raw: false);
      nativeMs = 7000; // 播放頭在 0；播放器仍停在別處。
      await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
      await tick(t, 3);
      expect(landings.length, 1);
      expect(clock, isNull, reason: '收件即回不能被當成定位完成');
      landings.single.complete(landed);
      await tick(t, 8);
      expect(isPlaying(), landed);
      expect(clock != null, landed);
      await close(t);
    });
  }

  for (final raw in [true, false]) {
    testWidgets('${raw ? '原檔' : '代理'}空快取拖曳容差正確，停手維持精準', (t) async {
      returnFrames = false;
      await open(t, raw: raw);
      await scrub(t, 1);
      expect(seeks.first['exact'], false);
      expect(seeks.first['toleranceMs'], raw ? 150 : 0);
      await tick(t, 8);
      expect(seeks.last['awaitCompletion'], true);
      expect(seeks.last['toleranceMs'], 0);
      await close(t);
    });
  }

  testWidgets('原生回傳偏遠幀不遮住目前影片，同一請求格仍去重', (t) async {
    detailedFrameReply = true;
    actualFrameTime = 2;
    await open(t);
    await scrub(t, 5);
    expect(frameRequests, isNotEmpty);
    expect(cache(), findsNothing, reason: '第2秒不能被標成要求的第5秒');
    final requested = frameRequests.length;
    for (var i = 0; i < 4; i++) {
      editorOf(t).onSeek(5.001);
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(frameRequests.length, requested, reason: '偏遠結果留request slot，不無限重抽');
    expect(cache(), findsNothing);
    expect(seeks.last['awaitCompletion'], isNot(true));
    await close(t);
  });

  testWidgets('actualSeconds為零是有效取樣時間，可在零秒附近粗覽', (t) async {
    detailedFrameReply = true;
    actualFrameTime = 0;
    await open(t);
    await scrub(t, 0.18);
    expect(cache(), findsOneWidget);
    await scrub(t, 5);
    expect(cache(), findsNothing, reason: '零秒不能回填成後續請求時間');
    await close(t);
  });

  testWidgets('大幅跳時後才返回的舊影格只存快取，不覆蓋新位置', (t) async {
    await open(t);
    final old = Completer<Object?>();
    heldFrame = old;
    editorOf(t).onSeek(1);
    await t.pump();
    expect(frameRequests.length, 1);
    editorOf(t).onSeek(5);
    await t.pump();
    final latest = Completer<Object?>();
    heldFrame = latest;
    old.complete({'bytes': frameBytes, 'actualSeconds': 1.0});
    await tick(t, 2, 20);
    expect(cache(), findsNothing);
    latest.complete({'bytes': frameBytes, 'actualSeconds': 5.0});
    await tick(t, 2, 20);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
    expect(cache(), findsOneWidget);
    expect(playheadOf(t), closeTo(5, 0.001));
    await close(t);
  });
}
