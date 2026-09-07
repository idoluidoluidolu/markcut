// 殭屍播放器自救（_reviveDeadComp）在合成模式也要啟動。
//
// 這個機制是為「系統媒體服務被重置（-11819）之後 AVPlayer 全部變殭屍：
// rate 起得來、時間不前進、抽不到畫面」設計的，而那正是合成模式（iOS
// 預設）才會踩到的情況。以前播放取樣器（_startPlayProbe）只在逐片段
// 那條路開，合成模式永遠不會重建、播放取樣診斷也是空的。
//
// 用假的 markcut/comp 通道演兩種情況：
//   1. 殭屍：play 之後位置一動不動 → 連續 2 秒沒前進 → 整組重建（build 第二次）
//   2. 尾巴：合成比時間軸短（馬賽克拖到影片之後），播放器到底停住是
//      正常的、時鐘自己走完尾巴 → 不能當成殭屍去重建
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';

Future<void> _tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

bool _isPlaying() => find.byIcon(Icons.pause_rounded).evaluate().isNotEmpty;

void main() {
  const compCh = MethodChannel('markcut/comp');
  var builds = 0;
  var nativeMs = 0;
  Timer? nativeClock;
  var compDuration = 5.0;
  // true＝第一次 play 之後時鐘不走（殭屍；重建之後那顆就活了，跟媒體
  // 服務重置後重開播放器一樣）；false＝正常前進、到合成結尾停住
  var zombie = false;
  var playCalls = 0;

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
    nativeMs = 0;
    zombie = false;
    playCalls = 0;
    compDuration = 5.0;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          builds++;
          return <String, dynamic>{
            'textureId': 1,
            'duration': compDuration,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
        case 'play':
          nativeClock?.cancel();
          playCalls++;
          if (!(zombie && playCalls == 1)) {
            nativeClock = Timer.periodic(const Duration(milliseconds: 33), (
              _,
            ) {
              // 到合成結尾就停住（真播放器 item 播完就不動了）
              final end = (compDuration * 1000).round();
              if (nativeMs < end) nativeMs = (nativeMs + 33).clamp(0, end);
            });
          }
          return '乾淨';
        case 'pause':
          nativeClock?.cancel();
          nativeClock = null;
          return null;
        case 'position':
          return nativeMs;
        case 'seek':
          final a = Map<Object?, Object?>.from(call.arguments as Map);
          nativeMs = ((a['sec'] as num) * 1000).round();
          return null;
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

  /// 馬賽克拖到影片之後：合成只到影片結尾（padTo 不算馬賽克），時間軸
  /// 卻到馬賽克結尾——播放時尾巴由 Dart 時鐘走完
  void addMosaic(TimelineModel tl, {required double at, required double len}) {
    tl.sources.add(
      MediaSource(
        path: '',
        name: 'mz',
        kind: ClipKind.mosaic,
        duration: 3600,
        mosaicStyle: MosaicStyle(),
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: len,
        offset: at,
        track: 1,
      ),
    );
  }

  Future<void> openWith(
    WidgetTester t,
    void Function(TimelineModel tl) fill,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        // 按鈕不畫墨水漣漪：--no-test-assets 下 ink_sparkle 的 shader 資產
        // 不在，點播放鍵會炸在跟這裡無關的地方
        theme: ThemeData(
          useMaterial3: true,
          splashFactory: NoSplash.splashFactory,
        ),
        home: const VideoEditorScreen(blank: true),
      ),
    );
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!(fill);
    await _tick(t, 15);
    expect(builds, 1, reason: '合成播放器要組起來');
  }

  Future<void> pressPlay(WidgetTester t) async {
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await _tick(t, 6, 33);
    expect(_isPlaying(), isTrue, reason: '按了播放要在播');
  }

  testWidgets('殭屍播放器（位置一動不動）：合成模式也會整組重建', (t) async {
    zombie = true;
    await openWith(t, (tl) => addVideo(tl, vidEnd: 5));
    await pressPlay(t);
    // 起播流程先等「影格滾起來」，殭屍永遠滾不起來，要等它 400ms 的牆鐘
    // 保底（Stopwatch 是真時間，假時間 pump 再多也不走）——所以每格順便
    // 讓真時間走一點。之後取樣器每 400ms（假時間）一次、連續 5 次沒前進
    // 才判死：這條迴圈的假時間有 5 秒、真時間有 3 秒，一定夠
    var rebuiltAt = -1;
    for (var i = 0; i < 150; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 33));
      if (builds >= 2) {
        rebuiltAt = i;
        break;
      }
    }
    expect(rebuiltAt, greaterThan(0), reason: '殭屍 2 秒後要整組重建（以前合成模式永遠不會）');
    expect(
      Diag.report(),
      contains('播放器卡死'),
      reason: '重建要留下診斷筆記',
    );
    // 重建後自己接著播（重建出來的那顆會動了）：影格滾起來、時鐘接著走
    await _tick(t, 20, 33);
    expect(_isPlaying(), isTrue, reason: '重建完要自己接著播');
    expect(playCalls, 2, reason: '重建後再起播一次');
    expect(nativeMs, greaterThan(0), reason: '新播放器的時鐘在走');
    // 停下來讓排著的計時器跑掉
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await _tick(t, 100);
  });

  testWidgets('尾巴專案（合成比時間軸短）：播放器到底停住不算殭屍，不重建', (t) async {
    // 影片 0~1、馬賽克 0~4 → 合成 1.0s、時間軸 4.0s
    compDuration = 1.0;
    await openWith(t, (tl) {
      addVideo(tl, vidEnd: 1);
      addMosaic(tl, at: 0, len: 4);
    });
    await pressPlay(t);
    // 走完整條時間軸（4s ＝ 122 格；多走一段確定已經停了）。播放器在
    // 1.0 停住 3 秒——比殭屍判定的 2 秒長，不能被誤殺
    var stopped = false;
    for (var i = 0; i < 170; i++) {
      await t.pump(const Duration(milliseconds: 33));
      if (!_isPlaying()) {
        stopped = true;
        break;
      }
    }
    expect(stopped, isTrue, reason: '時鐘要自己走完尾巴停下');
    expect(builds, 1, reason: '尾巴段播放器不前進是正常的，不能整組重建');
    expect(Diag.report(), isNot(contains('播放器卡死')));
    await _tick(t, 100);
  });

  testWidgets('正常播放：取樣器在合成模式有在取樣（診斷不再是空的）', (t) async {
    await openWith(t, (tl) => addVideo(tl, vidEnd: 5));
    await pressPlay(t);
    // 取樣器兩次之間量的是牆鐘（真時間 <50ms 的樣本會被丟掉當雜訊），
    // 所以每格也讓真時間走一點
    for (var i = 0; i < 40; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 33));
    }
    expect(Diag.playSamples, greaterThan(0), reason: '合成模式的播放也要有取樣');
    expect(builds, 1, reason: '正常前進不重建');
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await _tick(t, 100);
  });
}
