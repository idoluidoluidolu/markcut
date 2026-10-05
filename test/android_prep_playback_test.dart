// Android 的背景轉檔（media3 Transformer）停不下也放不慢：讓路＝整支作廢、
// 閒置後從頭重轉。實機 1.1.0+2232 的品質報告：轉到一半按播放，轉檔被
// 丟掉、整輪都在播 4K 原檔（ExoPlayer 貼圖，會頓），佇列一直是 1。
//
// 這裡用真的編輯頁走一遍：Android 的排程下，播放不叫原生讓路、轉檔照跑，
// 落地後暫停才換成工作檔；手指碰時間軸照舊讓路。iOS（預設）播放照舊
// 送「忙」——那邊只是放慢，進度留著
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/preview_preparation.dart';
import 'package:markcut/services/quality_diagnostics.dart';
import 'package:markcut/services/video_controller.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/widgets/prep_gate_view.dart';
import 'package:markcut/widgets/timeline_editor.dart';

import 'editor_harness.dart';

class _Player implements PlayerX {
  _Player(this.path);
  @override
  final String path;
  bool initialized = false;
  bool playing = false;
  bool disposed = false;
  Duration position = Duration.zero;

  /// 播放器自己量到的尺寸（mpv 開檔時紋理還沒起來會是 0x0）
  Size size = const Size(2160, 3840);

  /// 按下播放後前幾次問位置都還不動（mpv 起步要幾百毫秒）
  int startDelayPolls = 0;

  @override
  Future<void> initialize() async => initialized = true;

  @override
  PlayerValueX get value => PlayerValueX(
    isInitialized: initialized,
    isPlaying: playing,
    duration: const Duration(seconds: 6),
    position: position,
    size: size,
  );
  @override
  Future<void> play() async => playing = true;
  @override
  Future<void> pause() async => playing = false;
  @override
  Future<Duration?> positionNow() async {
    if (playing && startDelayPolls > 0) {
      startDelayPolls--;
      return position;
    }
    if (playing) position += const Duration(milliseconds: 33);
    return position;
  }

  @override
  Future<void> seekTo(Duration at) async => position = at;
  @override
  Future<void> setLooping(bool loop) async {}
  @override
  Future<void> setPlaybackSpeed(double speed) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  void dispose() {
    playing = false;
    disposed = true;
  }

  @override
  String get debugInfo => 'fake';
  @override
  Widget view({Key? key}) => ColoredBox(key: key, color: Colors.blue);
}

/// 照測試時鐘走的播放器：位置＝起點＋播了多久−[lag]（跟編輯器的時鐘
/// 同一條假時間，才量得出「落後幾秒」）
class _ClockPlayer extends _Player {
  _ClockPlayer(super.path, this.now);
  final DateTime Function() now;
  DateTime? _since;
  Duration _base = Duration.zero;
  Duration lag = Duration.zero;

  Duration get _pos =>
      (playing && _since != null
          ? _base + now().difference(_since!)
          : _base) -
      lag;

  @override
  PlayerValueX get value => PlayerValueX(
    isInitialized: initialized,
    isPlaying: playing,
    duration: const Duration(seconds: 6),
    position: _pos,
    size: size,
  );
  @override
  Future<void> play() async {
    if (!playing) _since = now();
    playing = true;
  }

  @override
  Future<void> pause() async {
    if (playing && _since != null) _base += now().difference(_since!);
    playing = false;
  }

  @override
  Future<Duration?> positionNow() async => _pos;
  @override
  Future<void> seekTo(Duration at) async {
    _base = at + lag;
    if (playing) _since = now();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late _Player original;
  _Player? work;
  var creates = 0;
  final sent = <Map<Object?, Object?>>[];
  var workCalls = 0;
  late Completer<String?> workDone;
  String? workDest;
  // 第一次轉檔當成「被手勢讓掉」回 deferred（原生端讓路時就是回這個）
  var deferFirst = false;
  // 第二次開工那一刻，原檔是不是正在播
  bool? playingAtSecondCall;
  // 原檔的尺寸（相機規格 vs 螢幕錄影），以及每支播放器開的時候要不要
  // 系統解碼器（false＝Android 上走 mpv）
  var probeW = 2160, probeH = 3840;
  final systemOf = <String, bool>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 逐片段播放器那條路（Android 沒有合成播放器）
    Diag.compPlayer.value = false;
    Diag.singlePlayer.value = false;
    Diag.playerLayer.value = false;
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    dir = Directory.systemTemp.createTempSync('markcut_android_prep_');
    WorkFiles.supportDirOverride = dir;
    final path = '${dir.path}/video.mp4';
    File(path).writeAsBytesSync([0]);
    original = _Player(path);
    work = null;
    creates = 0;
    sent.clear();
    workCalls = 0;
    workDone = Completer<String?>();
    workDest = null;
    deferFirst = false;
    playingAtSecondCall = null;
    probeW = 2160;
    probeH = 3840;
    systemOf.clear();
    bigPhoneView(binding);
    mockEditorPlugins(binding, tempDir: dir);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/prep'),
      (call) async {
        switch (call.method) {
          case 'available':
            return true;
          case 'probeLite':
            return <String, dynamic>{
              'durSec': 6.0,
              'w': probeW,
              'h': probeH,
              'sdr709': true,
              'codec': 'hvc1',
              'fps': 60.0,
            };
          case 'setInteractive':
            sent.add(Map.of(call.arguments as Map));
            return null;
          case 'toWorkFile':
            workCalls++;
            if (workCalls == 2) playingAtSecondCall = original.playing;
            if (deferFirst && workCalls == 1) {
              return <String, Object?>{
                'status': 'deferred',
                'reason': 'interaction',
              };
            }
            // 轉檔進行中：等測試說轉好了才回
            workDest = (call.arguments as Map)['dest'] as String;
            return workDone.future;
        }
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/export'),
      (_) async => false,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/frames'),
      (call) async => call.method == 'frameAt' ? solidPng(20, 40, 80) : null,
    );
  });
  tearDown(() async {
    // 轉檔槽是全域的：沒收尾的工作會讓下一支測試的轉檔永遠排隊
    if (!workDone.isCompleted) workDone.complete(null);
    await MediaPrep.setInteractive(false);
    Diag.compPlayer.value = true;
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester t, {required bool android}) async {
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(
          videoPath: original.path,
          thumbnailNow: t.binding.clock.now,
          debugAndroid: android,
          playerFactory: (path, {bool system = false}) {
            creates++;
            systemOf[path] = system;
            return path == original.path ? original : (work = _Player(path));
          },
        ),
      ),
    );
    await settle(t, 15);
    await t.pump(const Duration(seconds: 5));
    await settle(t, 6);
    expect(find.byType(PrepGateView), findsNothing);
    expect(modelOf(t).clips.length, 1);
    // 進場後背景開始轉工作檔（原生那邊還沒回）
    await waitUntil(t, () => workCalls == 1, reason: '進場後要開始轉工作檔');
  }

  Future<void> close(WidgetTester t) async {
    if (!workDone.isCompleted) workDone.complete(null);
    await settle(t, 3);
    await t.pumpWidget(const SizedBox());
    // 背景轉檔迴圈的閒置等待、轉完的色彩取樣（2 秒後取一次、再隔 0.7 秒
    // 取第二次）都是計時器：拆掉之後讓它們跑完（各自看到 !mounted 就收）
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(seconds: 2));
      await settle(t, 2);
    }
    expect(t.takeException(), isNull);
  }

  Iterable<Map<Object?, Object?>> yields(int from) =>
      sent.skip(from).where((m) => m['interactive'] == true);

  test('排程規則：Android 播放不讓路，iOS 照舊', () {
    expect(previewPrepYieldsToPlayback(android: true), isFalse);
    expect(previewPrepYieldsToPlayback(android: false), isTrue);
  });

  test('掉格計數只有 mpv 有：別的引擎回 null（不是「沒掉格」）', () async {
    final fake = _Player('/x.mp4');
    expect(await playerFrameStats(fake), isNull);
    expect(playerEngineName(fake), 'other');
  });

  test('報告優先處理：原檔卡在 ExoPlayer 才點名（原檔走 mpv 不算）', () {
    final d = QualityDiagnostics()..start(buildTag: 'test');
    d.increment('playbackSampleWorkFile');
    d.increment('playbackSampleOriginalFile');
    expect(
      d.priorities.join(),
      isNot(contains('ExoPlayer 播原檔')),
      reason: '原檔走 mpv 的取樣不該被當成問題',
    );
    d.increment('playbackSampleOriginalFile');
    d.increment('playbackSampleOriginalExo');
    d.increment('playbackSampleOriginalExo');
    expect(d.priorities.first, contains('播放取樣 2 次在用 ExoPlayer 播原檔'));
    expect(d.priorities.first, contains('工作檔 1 次'));
  });

  test('相機規格的尺寸才算（直式橫式都行），螢幕錄影那類怪尺寸不算', () {
    for (final (w, h) in const [
      (2160, 3840),
      (3840, 2160),
      (1080, 1920),
      (1920, 1080),
      (720, 1280),
      (1440, 2560),
      (4320, 7680),
    ]) {
      expect(isCameraVideoSize(w, h), isTrue, reason: '${w}x$h');
    }
    for (final (w, h) in const [
      (1080, 2410),
      (1440, 3200),
      (1080, 2340),
      (1080, 1080),
      (0, 0),
      (2160, 2160),
    ]) {
      expect(isCameraVideoSize(w, h), isFalse, reason: '${w}x$h');
    }
  });

  testWidgets('Android：相機規格的原檔第一次播放就交給 mpv（不等工作檔）', (t) async {
    await open(t, android: true);
    expect(systemOf[original.path], isFalse, reason: '原檔要走 mpv，不是 ExoPlayer');
    await close(t);
  });

  testWidgets('Android：螢幕錄影那類怪尺寸的原檔照舊系統解碼器', (t) async {
    probeW = 1080;
    probeH = 2410;
    await open(t, android: true);
    expect(systemOf[original.path], isTrue, reason: 'mpv 會把這類檔解成破圖');
    await close(t);
  });

  testWidgets('iOS（預設）：原檔照舊系統播放器', (t) async {
    await open(t, android: false);
    expect(systemOf[original.path], isTrue);
    await close(t);
  });

  testWidgets('Android：播放中轉檔不讓路，落地後暫停才換成工作檔', (t) async {
    await open(t, android: true);
    final before = sent.length;
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 15);
    expect(original.playing, isTrue);
    expect(
      yields(before),
      isEmpty,
      reason: '播放（含起播那一下）不能叫 Android 的轉檔讓路——讓路＝整支作廢',
    );
    expect(MediaPrep.debugScheduling.interactive, isFalse);

    // 播放中轉好了：畫面上的播放器不中途抽換
    File(workDest!).writeAsBytesSync(List.filled(64, 0));
    workDone.complete(workDest);
    await settle(t, 6);
    expect(modelOf(t).sources.first.workPath, workDest);
    expect(creates, 1, reason: '播放中不抽換播放器');
    expect(original.playing, isTrue);
    final playingCtx = QualityDiagnostics.instance.contextProvider!();
    expect(playingCtx['fallbackLeadUsesWorkFile'], isFalse);
    expect(playingCtx['fallbackLeadSourceChangePending'], isTrue);
    expect(playingCtx['fallbackLeadEngine'], 'other'); // 測試用假播放器

    // 暫停後閒置換檔，下一次播放播的是工作檔
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await tick(t, 20);
    await settle(t, 4);
    expect(work, isNotNull, reason: '暫停後要換成工作檔的播放器');
    expect(original.disposed, isTrue);
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 10);
    expect(work!.playing, isTrue);
    expect(playheadOf(t), greaterThan(0));
    final ctx = QualityDiagnostics.instance.contextProvider!();
    expect(ctx['fallbackLeadUsesWorkFile'], isTrue);
    expect(ctx['fallbackLeadSourceChangePending'], isFalse);
    expect(ctx.toString(), isNot(contains(dir.path)));
    await close(t);
  });

  testWidgets('Android：被讓掉的那支，播放中照樣重新開工', (t) async {
    deferFirst = true;
    await open(t, android: true);
    // 第一次被讓掉了，佇列在等開工；這時按播放
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 3);
    expect(original.playing, isTrue);
    // 重新開工那一路有真的檔案 I/O（工作檔索引、黑盒子），要真時間推
    await waitUntil(t, () => workCalls == 2, reason: '被讓掉的那支要重新開工');
    expect(
      playingAtSecondCall,
      isTrue,
      reason: '播放中就要重新開工（以前要等播放停了才開，整輪都播原檔）',
    );
    expect(QualityDiagnostics.instance.counters['previewPrepDeferred'], 1);
    if (isPlaying()) {
      await t.tap(find.byIcon(Icons.pause_rounded).first);
      await t.pump();
    }
    await close(t);
  });

  testWidgets('Android：播放中點一下時間軸不讓路（播放沒停，轉檔進度不丟）', (t) async {
    await open(t, android: true);
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 10);
    expect(original.playing, isTrue);
    final before = sent.length;
    await t.tapAt(t.getCenter(find.byType(TimelineEditor)));
    await tick(t, 25);
    expect(original.playing, isTrue, reason: '點一下不會停播放');
    expect(
      yields(before),
      isEmpty,
      reason: '播放中轉檔本來就在跑，點一下不多用解碼器，不值得整支作廢',
    );
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await t.pump();
    await close(t);
  });

  testWidgets('Android：手指碰時間軸照舊讓路（暫停解碼）', (t) async {
    await open(t, android: true);
    final before = sent.length;
    final g = await t.startGesture(t.getCenter(find.byType(TimelineEditor)));
    await g.moveBy(const Offset(-40, 0));
    await t.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(-40, 0));
    await t.pump(const Duration(milliseconds: 16));
    expect(
      yields(before).where((m) => m['pauseDecoding'] == true),
      isNotEmpty,
      reason: '拖曳要拿回解碼器（滑動優先）',
    );
    await g.up();
    await tick(t, 40);
    expect(sent.last['interactive'], isFalse, reason: '放手閒下來就收回讓路');
    await close(t);
  });

  testWidgets('iOS（預設）：播放照舊送「忙」，原生那邊只放慢', (t) async {
    await open(t, android: false);
    final before = sent.length;
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 15);
    expect(original.playing, isTrue);
    expect(yields(before), isNotEmpty);
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await t.pump();
    await close(t);
  });

  testWidgets('品質報告記得素材規格（只查匯入時探過的快取）', (t) async {
    await open(t, android: true);
    expect(MediaPrep.probedSpec(original.path), {
      'codec': 'hvc1',
      'fps': 60.0,
      'hdr': false,
    });
    await close(t);
  });

  // 實機 2235：mpv 開 4K 原檔那幾秒紋理還沒起來，播放器回報 0x0，編輯器
  // 退回 16:9 → 直式影片被壓扁，換成工作檔才正常
  testWidgets('播放器還沒量到尺寸（0x0）時照匯入探到的尺寸排，不壓扁', (t) async {
    original.size = Size.zero;
    await open(t, android: true);
    final clip = modelOf(t).clips.first;
    final layer = t.getSize(find.byKey(ValueKey('vidlayer${clip.id}')));
    expect(
      layer.width / layer.height,
      closeTo(2160 / 3840, 0.01),
      reason: '影片圖層要照素材的直式比例',
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is AspectRatio && (w.aspectRatio - 2160 / 3840).abs() < 0.01,
      ),
      findsWidgets,
      reason: '畫布「原始」比例要跟著素材是直式',
    );
    await close(t);
  });

  testWidgets('起播等影片真的動了才開時間軸的錶（mpv 起步要幾百毫秒）', (t) async {
    await open(t, android: true);
    // 按下播放後前 15 次問位置都不動（約 0.5 秒）
    original.startDelayPolls = 15;
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 40);
    final s = QualityDiagnostics.instance.samples[QualityMetric.playStart];
    expect(s?.failures ?? 0, 0, reason: '等得到影片起步，不能算逾時');
    expect(s?.count, 1);
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await t.pump();
    await close(t);
  });

  testWidgets('Android：帶頭的影片落後時鐘 0.25 秒以上，時鐘跟著它（不 seek）', (t) async {
    final timed = _ClockPlayer(original.path, t.binding.clock.now);
    original = timed;
    await open(t, android: true);
    await t.tap(find.byIcon(Icons.play_arrow_rounded).first);
    await tick(t, 25);
    final before = playheadOf(t);
    expect(before, greaterThan(0.3));
    // 播放器落後時鐘 0.4 秒（mpv 起步慢、或中途卡一下）
    timed.lag = const Duration(milliseconds: 400);
    await tick(t, 3);
    expect(
      playheadOf(t),
      lessThan(before),
      reason: '指針要退回去跟著畫面，不能一直超前',
    );
    await t.tap(find.byIcon(Icons.pause_rounded).first);
    await t.pump();
    await close(t);
  });
}
