// GIF 製作頁的匯出與預覽排程（稽核 #4、#18、#19、#21）：
//
// - 「做成 GIF」要等到「現在這組設定」的預覽做完才存：改設定 250ms 後
//   預覽就在做，這時按下來以前存的是上一份
// - 匯出中按「取消」：不存、不說成功、也不會把剛砍掉的工作又排回去跑
// - 背景預做隔壁選項時使用者改了設定：先砍掉預做、等它收工，再開使用者
//   那一支——同一時間最多一支 FFmpeg
// - 開頁掃掉上次留在暫存目錄的 preview_*.gif 半成品
// - 預覽時鐘只在播放中跑，暫停就停
//
// 這台沒有 FFmpeg 也沒有原生播放器：引擎與播放器都換成假的（GifScreen
// 的 debug* 替身）
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/gif_screen.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/video_controller.dart';

/// 假播放器：十秒、100×60，什麼都不播
class _FakePlayer implements PlayerX {
  _FakePlayer(this.path);

  @override
  final String path;
  bool playing = false;
  Duration pos = Duration.zero;

  @override
  Future<void> initialize() async {}

  @override
  PlayerValueX get value => PlayerValueX(
    isInitialized: true,
    isPlaying: playing,
    duration: const Duration(seconds: 10),
    position: pos,
    size: const Size(100, 60),
  );

  @override
  Future<Duration?> positionNow() async => pos;

  @override
  Future<void> seekTo(Duration d) async => pos = d;

  @override
  Future<void> play() async => playing = true;

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> setVolume(double v) async {}

  @override
  Future<void> setPlaybackSpeed(double s) async {}

  @override
  Future<void> setLooping(bool loop) async {}

  @override
  void dispose() {}

  @override
  Widget view({Key? key}) => SizedBox(key: key);

  @override
  String get debugInfo => 'fake';
}

/// 一支「FFmpeg 工作」：等測試叫它完成（真的寫一個 GIF 檔）或取消（null）
class _Job {
  _Job(this.fps, this.size, this.start, this.end);
  final int fps;
  final int size;
  final double start;
  final double end;
  final c = Completer<String?>();
  bool get done => c.isCompleted;
}

class _FakeEngine {
  _FakeEngine(this.dir, this.gifBytes);
  final Directory dir;
  final Uint8List gifBytes;
  final jobs = <_Job>[];
  final saved = <String>[];
  int inFlight = 0;
  int maxInFlight = 0;
  int cancels = 0;

  Future<String?> make({
    required String inputPath,
    required double start,
    required double end,
    required int fps,
    required int maxSide,
    Rect? crop,
    double speed = 1.0,
  }) {
    final j = _Job(fps, maxSide, start, end);
    jobs.add(j);
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    return j.c.future.whenComplete(() => inFlight--);
  }

  String finish(_Job j) {
    final p =
        '${dir.path}${Platform.pathSeparator}preview_${jobs.indexOf(j)}.gif';
    File(p).writeAsBytesSync(gifBytes);
    j.c.complete(p);
    return p;
  }

  Future<void> cancel() async {
    cancels++;
    for (final j in jobs) {
      if (!j.done) j.c.complete(null);
    }
  }

  Future<({bool ok, String message, bool cancelled})> save(String p) async {
    saved.add(p);
    return (ok: true, message: '已把 GIF 存到「浮水印」相簿', cancelled: false);
  }

  List<_Job> get pending => [
    for (final j in jobs)
      if (!j.done) j,
  ];
}

Uint8List _gifBytes() {
  final enc = img.GifEncoder(numColors: 8);
  for (var f = 0; f < 3; f++) {
    final im = img.Image(width: 40, height: 24);
    for (var y = 0; y < 24; y++) {
      for (var x = 0; x < 40; x++) {
        im.setPixelRgb(x, y, x * 6, y * 10, f * 100);
      }
    }
    enc.addFrame(im, duration: 8);
  }
  return enc.finish()!;
}

late Directory _dir;
late _FakeEngine _engine;

/// ffmpeg_kit 的事件通道（EventChannel 的 listen／cancel 走的也是
/// MethodChannel 那套二進位協定，接得起來）
const _ffmpegEvents = 'flutter.arthenica.com/ffmpeg_kit_event';

/// 真的 I/O（掃暫存、解 GIF）＋假時間的計時器都要推：
/// 每一輪讓真的跑一下、再讓假時間走 [step]
Future<void> _settle(
  WidgetTester t, {
  int rounds = 5,
  Duration step = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(step);
  }
}

dynamic _state(WidgetTester t) => t.state(find.byType(GifScreen));

/// 等到 [ready]（真 I/O 與通道往返都要幾輪），等不到就讓斷言自己講
Future<void> _waitFor(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 40 && !ready(); i++) {
    await _settle(t, rounds: 1);
  }
}

/// 開頁、等第一份預覽（12fps／480p）做好
Future<_Job> _open(WidgetTester t) async {
  await t.pumpWidget(
    const MaterialApp(
      home: GifScreen(path: 'v.mp4', name: 'v.mp4'),
    ),
  );
  await _settle(t);
  expect(find.text('做成 GIF'), findsOneWidget, reason: '頁面要開得起來');
  // 250ms 的防抖之後第一份預覽開跑
  await t.pump(const Duration(milliseconds: 300));
  await _waitFor(t, () => _engine.jobs.isNotEmpty);
  expect(_engine.jobs, hasLength(1));
  final first = _engine.jobs.single;
  expect((first.fps, first.size), (12, 480));
  return first;
}

/// 讓一支工作完成、等頁面把它換上（解幀是真的 I/O）
Future<String> _finish(WidgetTester t, _Job j) async {
  final p = _engine.finish(j);
  await _settle(t, rounds: 8);
  return p;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _dir = Directory.systemTemp.createTempSync('gif_flow_');
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => _dir.path,
        );
    // 縮圖帶抽不到畫面（這台沒有原生解碼器）就會退 FFmpeg：ffmpeg_kit
    // 一被載入就去訂它的事件通道，這台沒有實作＝一個沒人接的
    // MissingPluginException 飄進測試。抽幀本身失敗是預期的（回空清單），
    // 這裡只是把那個通道接起來，不然它會蓋掉真正要驗的東西
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(_ffmpegEvents),
          (_) async => null,
        );
    _engine = _FakeEngine(_dir, _gifBytes());
    GifScreen.debugPlayer = _FakePlayer.new;
    GifScreen.debugMakeGif = _engine.make;
    GifScreen.debugSaveGif = _engine.save;
    GifScreen.debugCancel = _engine.cancel;
  });

  tearDown(() {
    GifScreen.debugPlayer = null;
    GifScreen.debugMakeGif = null;
    GifScreen.debugSaveGif = null;
    GifScreen.debugCancel = null;
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      )
      ..setMockMethodCallHandler(const MethodChannel(_ffmpegEvents), null);
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('開頁掃掉上次留下的 preview_*.gif；預覽做好換上；時鐘只在播放中跑', (t) async {
    final stale = File('${_dir.path}${Platform.pathSeparator}preview_123.gif')
      ..writeAsBytesSync(_gifBytes());
    final other = File('${_dir.path}${Platform.pathSeparator}mk_1.png')
      ..writeAsBytesSync([1, 2, 3]);
    final first = await _open(t);
    expect(stale.existsSync(), isFalse, reason: '上次的半成品開頁就該清');
    expect(other.existsSync(), isTrue, reason: '別的暫存檔不碰');

    await _finish(t, first);
    expect(_state(t).previewKey, isNotEmpty, reason: '第一份預覽要換上');
    expect(_state(t).gifFrameBytes, 3 * 40 * 24 * 4, reason: '三幀 40×24 的 RGBA');
    expect(_state(t).gifTickRunning, isTrue, reason: '播放中時鐘在跑');

    // 暫停：時鐘停；再播：時鐘回來
    await t.tap(find.byIcon(Icons.pause_rounded));
    await t.pump(const Duration(milliseconds: 100));
    expect(_state(t).gifTickRunning, isFalse, reason: '暫停就不該每 33ms 空轉');
    await t.tap(find.byIcon(Icons.play_arrow_rounded));
    await t.pump(const Duration(milliseconds: 50));
    expect(_state(t).gifTickRunning, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('改設定後馬上按「做成 GIF」：等新的那份做好才存，存的不是舊的', (t) async {
    final first = await _open(t);
    final firstPath = await _finish(t, first);

    // 改順暢度：250ms 後第二份開跑
    await t.tap(find.text('15 fps'));
    await t.pump(const Duration(milliseconds: 300));
    await _waitFor(t, () => _engine.pending.any((j) => j.fps == 15));
    final second = _engine.pending.singleWhere((j) => j.fps == 15);

    // 第二份還在做的時候按匯出
    await t.tap(find.text('做成 GIF'));
    await _settle(t, rounds: 2);
    expect(find.text('製作 GIF 中…'), findsOneWidget);
    expect(_engine.saved, isEmpty, reason: '新的還沒做好，不能先存舊的');

    final secondPath = await _finish(t, second);
    await _settle(t, rounds: 6);
    expect(_engine.saved, [secondPath], reason: '存的要是改完設定的那一份');
    expect(_engine.saved, isNot(contains(firstPath)));
    expect(find.text('匯出完成'), findsOneWidget);
    await t.tap(find.text('繼續編輯'));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
  });

  testWidgets('匯出中按取消：不存、不說成功、也不會把砍掉的工作再排回去', (t) async {
    final first = await _open(t);
    await _finish(t, first);
    await t.tap(find.text('15 fps'));
    await t.pump(const Duration(milliseconds: 300));
    await _waitFor(t, () => _engine.pending.any((j) => j.fps == 15));
    expect(_engine.pending, hasLength(1));

    await t.tap(find.text('做成 GIF'));
    await _settle(t, rounds: 2);
    await t.tap(find.text('取消'));
    await t.pump();
    expect(find.text('取消中…'), findsOneWidget);
    await _settle(t, rounds: 6);
    expect(_engine.cancels, greaterThanOrEqualTo(1));
    expect(_engine.saved, isEmpty, reason: '取消了不能存');
    expect(find.text('製作 GIF 中…'), findsNothing);
    expect(find.text('匯出完成'), findsNothing, reason: '取消不能說成功');
    expect(find.text('已取消'), findsOneWidget);

    // 之後閒著：被砍掉的那份不會自己再跑一次
    final jobsAfter = _engine.jobs.length;
    await _settle(t, rounds: 10, step: const Duration(milliseconds: 300));
    expect(_engine.jobs.length, jobsAfter, reason: '取消後不該自動補做');
    expect(_engine.pending, isEmpty);

    // 使用者再按一次才做：做完照存
    await t.tap(find.text('做成 GIF'));
    await _waitFor(t, () => _engine.pending.isNotEmpty);
    final again = _engine.pending.single;
    expect(again.fps, 15);
    final p = await _finish(t, again);
    await _settle(t, rounds: 6);
    expect(_engine.saved, [p]);
    await t.tap(find.text('繼續編輯'));
    await t.pump(const Duration(milliseconds: 300));
    expect(t.takeException(), isNull);
  });

  testWidgets('背景預做時改設定：先砍掉預做、等它收工再開使用者那一支，同時最多一支', (t) async {
    final first = await _open(t);
    await _finish(t, first);
    // 縮圖帶抽完＋閒置 1.2 秒 → 背景預做隔壁選項
    for (var i = 0; i < 20 && _engine.pending.isEmpty; i++) {
      await _settle(t, rounds: 2, step: const Duration(milliseconds: 200));
    }
    expect(_engine.pending, hasLength(1), reason: '閒下來要開始預做');
    final prefetch = _engine.pending.single;
    expect((prefetch.fps, prefetch.size), isNot((12, 480)));

    // 使用者改尺寸：預做那支要被砍掉、等它收工，使用者的那支才開
    await t.tap(find.text('640p'));
    await t.pump(const Duration(milliseconds: 300));
    await _waitFor(t, () => _engine.pending.any((j) => j.size == 640));
    expect(prefetch.done, isTrue, reason: '預做的要先被砍掉');
    expect(_engine.cancels, greaterThanOrEqualTo(1));
    final mine = _engine.pending.single;
    expect((mine.fps, mine.size), (12, 640));
    expect(_engine.maxInFlight, 1, reason: '兩支 FFmpeg 不能同時跑');

    final p = await _finish(t, mine);
    expect(_state(t).previewKey, contains('@640@'));
    expect(File(p).existsSync(), isTrue);
    expect(t.takeException(), isNull);
  });
}
