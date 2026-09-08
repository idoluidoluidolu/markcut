// 迴歸守門：測試員回報「影片播到最後會黑掉，應該正常要停留在最後一幀」。
//
// 根因在 Flutter 端的兩個閘門（原生播放器停在 item 尾端本來就顯示最後
// 一幀）：
//   1. _pause 拿播放器「真正停在哪」回填 _position。合成常比時間軸長
//      （聲音軌多幾毫秒、片段重疊被原生端往後推、timescale 捨入；實機
//      診斷：合成 5.54s、時間軸 4.92s），播完那一刻播放器落在時間軸終點
//      「之後」——回填進來播放頭底下沒有任何片段，預覽層的 Opacity 閘門
//      （cur != null || CompPlayer.paintsAt）把合成畫面整層藏掉＝黑。
//      修法：走到終點而停的那次暫停（_pause(atEnd: true)）指針釘在終點、
//      不回填；一般暫停的回填夾在時間軸內。
//   2. CompPlayer.paintsAt 在 t ≥ 合成結尾一律藏。尾巴專案（圖片/文字比
//      影片長、合成補長到時間軸終點）播到終點時播放頭底下沒有影片，
//      只剩這條規則說話＝藏＝黑。修法：合成結尾那一格（含 0.05s 捨入
//      容差）露——播放器停在那裡顯示的就是最後一幀。
//
// 這裡用假的 markcut/comp 通道把「播放器停在終點之後」演出來，走真的
// 編輯器：按播放、時鐘走到底、看合成畫面那層的 Opacity 是不是 1、指針
// 是不是釘在終點、再按播放是不是從頭。
import 'dart:async';

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

/// 合成畫面那層（Texture）外面的 Opacity 閘門現在開多少：1＝露、0＝藏（黑）
double _compOpacity(WidgetTester t) {
  final tex = find.byType(Texture);
  expect(tex, findsOneWidget, reason: '合成材質要在畫面上');
  final gate = find.ancestor(of: tex, matching: find.byType(Opacity)).first;
  return t.widget<Opacity>(gate).opacity;
}

double _playhead(WidgetTester t) =>
    t.widget<TimelineEditor>(find.byType(TimelineEditor)).playhead.value;

bool _isPlaying() => find.byIcon(Icons.pause_rounded).evaluate().isNotEmpty;

void main() {
  const compCh = MethodChannel('markcut/comp');
  late List<Map<Object?, Object?>> seeks;
  var builds = 0;

  // 假播放器：play 之後時鐘跟著測試的假時間走（每 33ms 前進 33ms，跟
  // 編輯器的 ticker 同步）；pause 停在 [stopAtMs]（給了的話）——用來
  // 演「合成比時間軸長，播放器停的位置落在時間軸終點之後」
  var nativeMs = 0;
  Timer? nativeClock;
  int? stopAtMs;
  var compDuration = 5.0;
  Completer<int>? heldPosition;
  Completer<Map<String, dynamic>>? heldBuild;
  var nativeStalled = false;
  var positionUnavailable = false;
  int? capNativeAtMs;
  var positionQueries = 0;

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
    Diag.reset();
    // 測試環境沒有真的原生 UiKitView：合成畫面走 Texture，閘門才找得到
    Diag.playerLayer.value = false;
    seeks = [];
    builds = 0;
    nativeMs = 0;
    stopAtMs = null;
    compDuration = 5.0;
    heldPosition = null;
    heldBuild = null;
    nativeStalled = false;
    positionUnavailable = false;
    capNativeAtMs = null;
    positionQueries = 0;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          builds++;
          if (heldBuild != null) {
            final pending = heldBuild!;
            heldBuild = null;
            return pending.future;
          }
          return <String, dynamic>{
            'textureId': 1,
            'duration': compDuration,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
        case 'play':
          nativeClock?.cancel();
          nativeClock = Timer.periodic(const Duration(milliseconds: 33), (_) {
            if (nativeStalled) return;
            nativeMs += 33;
            if (capNativeAtMs != null && nativeMs > capNativeAtMs!) {
              nativeMs = capNativeAtMs!;
            }
          });
          return '乾淨';
        case 'pause':
          nativeClock?.cancel();
          nativeClock = null;
          if (stopAtMs != null) nativeMs = stopAtMs!;
          return null;
        case 'dispose':
          nativeClock?.cancel();
          nativeClock = null;
          return null;
        case 'position':
          positionQueries++;
          if (positionUnavailable) {
            throw PlatformException(code: 'position-unavailable');
          }
          if (heldPosition != null) {
            final pending = heldPosition!;
            heldPosition = null;
            return pending.future;
          }
          return nativeMs;
        case 'seek':
          final a = Map<Object?, Object?>.from(call.arguments as Map);
          seeks.add(a);
          nativeMs = ((a['sec'] as num) * 1000).round();
          return a['awaitCompletion'] == true ? true : null;
        case 'setHiddenImageTracks':
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    nativeClock?.cancel();
    nativeClock = null;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
  });

  /// 影片 0~[vidEnd] 秒（給 workPath＝不探 HDR、不碰檔案系統）
  void addVideo(TimelineModel tl, {double vidEnd = 5}) {
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
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: vidEnd,
        offset: 0,
        track: 0,
      ),
    );
  }

  /// 文字素材（尾巴只有文字時合成補長到時間軸終點，跟 padTo 一致）
  void addText(TimelineModel tl, {required double at, required double len}) {
    tl.sources.add(
      MediaSource(path: '', name: 'hi', kind: ClipKind.text, duration: 3600),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: len,
        offset: at,
        track: 3,
      ),
    );
  }

  /// 開空白編輯器、塞時間軸、等 350ms 併批＋假的 build 回來
  Future<void> openWith(
    WidgetTester t,
    void Function(TimelineModel tl) fill,
  ) async {
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
    await _tick(t, 5);
    final debugTimeline = VideoEditorScreen.debugTimeline;
    expect(debugTimeline, isNotNull);
    debugTimeline!(fill);
    await _tick(t, 15);
    expect(builds, 1, reason: '合成播放器要組起來');
    expect(_compOpacity(t), 1.0, reason: '起點那格要露');
    seeks.clear();
  }

  /// 按播放，等起播流程（問位置→起播→影格滾起來→ticker 開走）
  Future<void> pressPlay(WidgetTester t) async {
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await _tick(t, 6, 33);
    expect(_isPlaying(), isTrue, reason: '按了播放要在播');
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  }

  testWidgets('起播400ms未前進：等待期間指標不空走，恢復後直接跟隨原生位置', (t) async {
    nativeStalled = true;
    await openWith(t, (tl) => addVideo(tl));
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await t.pump();
    expect(nativeClock, isNotNull);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 450)),
    );
    await _tick(t, 20, 33);
    expect(_isPlaying(), isTrue);
    expect(nativeMs, 0);
    expect(
      _playhead(t),
      0,
      reason: 'timeout starts native polling, not a fake clock',
    );
    nativeStalled = false;
    await _tick(t, 10, 33);
    expect(_playhead(t), greaterThan(0));
    expect(_playhead(t), closeTo(nativeMs / 1000, 0.001));
    expect(seeks, isEmpty, reason: 'recovery cannot use correction seeks');
    await close(t);
  });

  testWidgets('播放途中停滯：時間碼固定在原生位置，恢復後無追趕或校正seek', (t) async {
    await openWith(t, (tl) => addVideo(tl));
    await pressPlay(t);
    await _tick(t, 15, 33);
    nativeStalled = true;
    await _tick(t, 2, 33);
    final stopped = nativeMs / 1000;
    await _tick(t, 20, 33);
    expect(_playhead(t), closeTo(stopped, 0.001));
    nativeStalled = false;
    await _tick(t, 5, 33);
    expect(_playhead(t), closeTo(nativeMs / 1000, 0.001));
    expect(seeks, isEmpty);
    await close(t);
  });

  testWidgets('位置讀取失敗：保留播放頭，不能把未知位置當成零', (t) async {
    await openWith(t, (tl) => addVideo(tl));
    await pressPlay(t);
    await _tick(t, 15, 33);
    nativeStalled = true;
    await _tick(t, 2, 33);
    final before = _playhead(t);
    positionUnavailable = true;
    await _tick(t, 85, 33);
    expect(_playhead(t), before);
    expect(
      builds,
      1,
      reason: 'missing data cannot count as a confirmed decoder stall',
    );
    expect(Diag.report(), isNot(contains('播放器卡死')));
    positionUnavailable = false;
    nativeStalled = false;
    await _tick(t, 5, 33);
    expect(_playhead(t), closeTo(nativeMs / 1000, 0.001));
    expect(seeks, isEmpty);
    await close(t);
  });

  testWidgets('位置查询未完成不重複堆積，暫停後舊回覆不移動播放頭', (t) async {
    await openWith(t, (tl) => addVideo(tl));
    await pressPlay(t);
    final delayed = Completer<int>();
    heldPosition = delayed;
    final queriesBefore = positionQueries;
    await _tick(t, 85, 33);
    expect(
      positionQueries - queriesBefore,
      1,
      reason: 'clock and probe share one query',
    );
    expect(
      builds,
      1,
      reason: 'a slow channel reply is not a fresh stalled sample',
    );
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await t.pump();
    final paused = _playhead(t);
    delayed.complete(0);
    await _tick(t, 8, 33);
    expect(_playhead(t), paused);
    expect(_isPlaying(), isFalse);
    await close(t);
  });

  testWidgets('連續兩秒真正沒有前進仍會重建卡死播放器', (t) async {
    await openWith(t, (tl) => addVideo(tl));
    await pressPlay(t);
    nativeStalled = true;
    await _tick(t, 100, 33);
    expect(Diag.report(), contains('播放器卡死'));
    expect(
      builds,
      greaterThan(1),
      reason: 'native clock stalls retain the existing recovery',
    );
    await close(t);
  });

  testWidgets('最後50ms停滯不啟動文字尾段，真正到影片終點後尾段正常走完', (t) async {
    compDuration = 1;
    capNativeAtMs = 950;
    await openWith(t, (tl) {
      addVideo(tl, vidEnd: 1);
      addText(tl, at: 0, len: 3);
    });
    await pressPlay(t);
    await _tick(t, 45, 33);
    expect(nativeMs, 950);
    expect(_playhead(t), 0.95);
    expect(_isPlaying(), isTrue);
    capNativeAtMs = 1000;
    await _tick(t, 80, 33);
    expect(nativeMs, 1000);
    expect(_playhead(t), 3);
    expect(_isPlaying(), isFalse);
    expect(seeks, isEmpty);
    await close(t);
  });

  testWidgets('播放起步等待位置時按暫停：舊請求不能再次啟動播放器', (t) async {
    await openWith(t, (tl) => addVideo(tl));
    final pending = Completer<int>();
    heldPosition = pending;
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await t.pump();
    expect(_isPlaying(), isTrue);
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await t.pump();
    expect(_isPlaying(), isFalse);
    pending.complete(0);
    await _tick(t, 20);
    expect(nativeClock, isNull, reason: '已取消的起播不得在 pause 後再送 play');
    expect(nativeMs, 0);
    expect(_playhead(t), 0);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('重建中按播放：等新播放器就緒後照常起播', (t) async {
    await openWith(t, (tl) => addVideo(tl));
    final pending = Completer<Map<String, dynamic>>();
    heldBuild = pending;
    VideoEditorScreen.debugTimeline!((tl) => tl.clips.first.volume = 0.5);
    await _tick(t, 12);
    expect(builds, 2);
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await t.pump();
    expect(_isPlaying(), isTrue);
    expect(nativeClock, isNull);
    pending.complete({
      'textureId': 2,
      'duration': compDuration,
      'width': 1080.0,
      'height': 1920.0,
      'ci': true,
    });
    await _tick(t, 15);
    expect(nativeClock, isNotNull);
    expect(nativeMs, greaterThan(0));
    expect(_playhead(t), greaterThan(0));
    expect(t.takeException(), isNull);
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await t.pump();
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('一般專案、合成比時間軸長：播到終點停下、畫面不藏、指針釘在終點、再按播放從頭', (t) async {
    // 時間軸 5.0s；合成 5.54s（實機診斷的形狀：聲音軌／重疊讓合成更長）
    compDuration = 5.54;
    // 播完那一刻播放器落在時間軸終點之後 30ms
    stopAtMs = 5030;
    await openWith(t, (tl) => addVideo(tl, vidEnd: 5));

    await pressPlay(t);
    // 時鐘走到底（5s ＝ 152 格；多走一段確定已經停了）
    var stoppedAt = -1;
    for (var i = 0; i < 200; i++) {
      await t.pump(const Duration(milliseconds: 33));
      if (!_isPlaying()) {
        stoppedAt = i;
        break;
      }
      expect(_compOpacity(t), 1.0, reason: '播放中第 $i 格不能黑');
    }
    expect(stoppedAt, greaterThan(0), reason: '走到終點要自己停下');
    await _tick(t, 5);

    expect(_isPlaying(), isFalse);
    expect(
      _playhead(t),
      closeTo(5.0, 1e-6),
      reason: '指針釘在時間軸終點，不被播放器的 5.03 推過去',
    );
    expect(_compOpacity(t), 1.0, reason: '播完停在最後一幀：合成畫面那層不能藏（黑）');
    expect(seeks, isEmpty, reason: '播完不另外 seek（會退回前一格）');

    // 再按播放：從頭開始（先 seek 到 0 再起播）
    await pressPlay(t);
    expect(seeks, isNotEmpty);
    expect((seeks.first['sec'] as num).toDouble(), 0.0, reason: '從頭');
    await _tick(t, 10, 33);
    expect(_playhead(t), lessThan(1.0));
    expect(_compOpacity(t), 1.0);

    // 收尾：停下來，讓排著的計時器（存草稿、1.7s 清覆寫）跑掉
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await _tick(t, 100);
  });

  testWidgets('尾巴專案（文字比影片長、合成補長到終點）：播到終點畫面不藏', (t) async {
    // 影片 0~1、文字 0~4 → padTo = 4.0 → 合成 4.0s
    compDuration = 4.0;
    stopAtMs = 4000;
    await openWith(t, (tl) {
      addVideo(tl, vidEnd: 1);
      addText(tl, at: 0, len: 4);
    });

    await pressPlay(t);
    var stopped = false;
    for (var i = 0; i < 170; i++) {
      await t.pump(const Duration(milliseconds: 33));
      if (!_isPlaying()) {
        stopped = true;
        break;
      }
      // 尾巴（影片播完之後）是原生合成器畫的黑底＋Flutter 的文字，
      // 每一格都要露——上一輪修過的那個症狀
      expect(_compOpacity(t), 1.0, reason: '第 $i 格不能藏');
    }
    expect(stopped, isTrue);
    await _tick(t, 5);

    expect(_playhead(t), closeTo(4.0, 1e-6));
    expect(
      _compOpacity(t),
      1.0,
      reason: '終點那格播放頭底下沒有影片、只剩 paintsAt 說話：合成結尾那格要露',
    );
    await _tick(t, 100);
  });

  testWidgets('拖到最尾端：畫面不藏、送精準 seek 到終點', (t) async {
    compDuration = 5.54;
    await openWith(t, (tl) => addVideo(tl, vidEnd: 5));

    final tlWidget = t.widget<TimelineEditor>(find.byType(TimelineEditor));
    tlWidget.onSeek(5.0);
    await _tick(t, 12, 40); // 220ms 收尾＋90ms 對齊回彈
    expect(_playhead(t), closeTo(5.0, 1e-6));
    expect(_compOpacity(t), 1.0, reason: '拖到底要停在最後一幀，不能黑');
    expect(
      seeks.any(
        (s) => (s['sec'] as num).toDouble() == 5.0 && s['exact'] == true,
      ),
      isTrue,
      reason: '放手要送精準 seek 到終點（原生端夾在最後一格之前）',
    );
    await _tick(t, 100);
  });
}
