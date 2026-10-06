// 換段（放大膠卷版，使用者在畫布上挑的「乙」）：
//   1. 大預覽在上；下面一條細的整支縮圖、一條放大膠卷；只寫起訖，沒有說明字
//   2. 放大膠卷：框固定在中間、框寬＝片段長度；拖膠卷＝細調，放手才提交
//   3. 整支縮圖：點一下＝框的中間移到那裡，拖＝框跟著走（大跳）
//   4. 大預覽是活的：預設不播、音量照片段；點一下循環播這一段；拖的時候
//      停播、畫面跟著換開頭；放手從新的開頭自動播
//   5. 播放器開不起來：退回開頭畫面（一次只抽一張、最新的優先）
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/video_controller.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/slip_film.dart';
import 'package:markcut/widgets/slip_picker.dart';
import 'package:markcut/widgets/slip_strip.dart';

import 'editor_harness.dart' show solidPng;

Finder get _strip => find.byKey(const ValueKey('slip-strip'));
Finder get _film => find.byKey(const ValueKey('slip-film'));
Finder get _preview => find.byKey(const ValueKey('slip-preview'));
Finder get _window => find.byKey(const ValueKey('slip-window'));
Finder get _image =>
    find.descendant(of: _preview, matching: find.byType(Image));

/// 假播放器：20 秒直式影片，記下 seek／音量／播放狀態
class _FakePlayer implements PlayerX {
  _FakePlayer(this.path, {this.fail = false});

  @override
  final String path;
  final bool fail;
  bool playing = false;
  bool disposed = false;
  Duration pos = Duration.zero;
  double? volume;
  final seeks = <Duration>[];

  @override
  Future<void> initialize() async {
    if (fail) throw StateError('no decoder');
  }

  @override
  PlayerValueX get value => PlayerValueX(
    isInitialized: true,
    isPlaying: playing,
    duration: const Duration(seconds: 20),
    position: pos,
    size: const Size(1080, 1920),
  );

  @override
  Future<Duration?> positionNow() async => pos;

  @override
  Future<void> seekTo(Duration d) async {
    seeks.add(d);
    pos = d;
  }

  @override
  Future<void> play() async => playing = true;

  @override
  Future<void> pause() async => playing = false;

  @override
  Future<void> setVolume(double v) async => volume = v;

  @override
  Future<void> setPlaybackSpeed(double s) async {}

  @override
  Future<void> setLooping(bool loop) async {}

  @override
  void dispose() => disposed = true;

  @override
  Widget view({Key? key}) => ColoredBox(key: key, color: Colors.blueGrey);

  @override
  String get debugInfo => 'fake';
}

Future<void> _open(
  WidgetTester t, {
  double start = 2,
  double duration = 20,
  double length = 4,
  Future<Uint8List?> Function(double)? load,
  Future<Uint8List?> Function(double)? thumbnail,
  Future<Uint8List?> Function(double seconds, double tolerance)? tiles,
  ValueChanged<double>? commit,
  double textScale = 1,
  String? playPath,
  double volume = 1,
}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
      home: Scaffold(
        backgroundColor: kBg,
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: 0.88,
              child: SlipPicker(
                duration: duration,
                start: start,
                length: length,
                playPath: playPath,
                volume: volume,
                aspect: 9 / 16,
                loadFrame: load ?? (_) async => null,
                loadThumbnail:
                    tiles ?? (s, _) => (thumbnail ?? (_) async => null)(s),
                onCommit: commit ?? (_) {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

/// 點整支縮圖，讓框的中間落在 [seconds]
Future<void> _tapStrip(WidgetTester t, double seconds, double duration) async {
  final rect = t.getRect(_strip);
  await t.tapAt(
    Offset(rect.left + seconds / duration * rect.width, rect.center.dy),
  );
  await t.pump();
}

/// 拖膠卷 [dx] 像素（膠卷黏著手指：過門檻前那一段也算）
Future<TestGesture> _dragFilm(WidgetTester t, double dx, {bool up = true}) async {
  final g = await t.startGesture(t.getCenter(_film));
  await g.moveBy(Offset(dx, 0));
  await t.pump();
  if (up) {
    await g.up();
    await t.pump();
  }
  return g;
}

void main() {
  late _FakePlayer player;
  tearDown(() => SlipPicker.debugPlayer = null);

  void usePlayer({bool fail = false}) {
    SlipPicker.debugPlayer = (p) => player = _FakePlayer(p, fail: fail);
  }

  group('排法', () {
    test('框寬四成、一秒幾像素由片段長度決定；格子按時間切', () {
      final g = SlipFilmGeometry(
        width: 350,
        height: 64,
        duration: 20,
        length: 4,
        aspect: 9 / 16,
      );
      expect(g.windowWidth, 140);
      expect(g.centeredLeft, 105);
      expect(g.pps, 35);
      expect(g.scrolls, isTrue);
      expect(g.maxView, 10, reason: '膠卷一條看得到 10 秒，左緣最多到 10 秒');
      expect(g.tileWidth, 36);
      expect(g.step, closeTo(36 / 35, 1e-9));
      // 片尾那格只取片內那一截的中間
      final last = g.tileCount - 1;
      expect(g.tileTime(last), closeTo((last * g.step + 20) / 2, 1e-9));
      expect(g.tileSpan(last), closeTo(20 - last * g.step, 1e-9));
    });

    test('框盡量放正中間，但膠卷不露出原片頭尾以外的空白', () {
      final g = SlipFilmGeometry(
        width: 350,
        height: 64,
        duration: 20,
        length: 4,
        aspect: 9 / 16,
      );
      // 中段：框正中間
      expect(g.restView(8), 5);
      expect(g.xOf(8, g.restView(8)), 105);
      // 開頭只有 2 秒：膠卷從 0 秒排起，框靠左（不露出 0 秒以前的空白）
      expect(g.restView(2), 0);
      expect(g.xOf(2, 0), 70);
      expect(g.visibleTiles(0), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      // 貼著片尾（使用者回報的情況）：框靠右，右邊不留空白
      expect(g.restView(16), 10);
      expect(g.xOf(20, 10), 350, reason: '片尾剛好在膠卷右緣');
    });

    test('片段超過原片四成：膠卷就是整支原片，不比上面那條還粗', () {
      final g = SlipFilmGeometry(
        width: 350,
        height: 64,
        duration: 20,
        length: 10,
      );
      expect(g.pps, 17.5, reason: '整支 20 秒剛好排滿 350 像素');
      expect(g.windowWidth, 175);
      expect(g.scrolls, isFalse);
      expect(g.restView(10), 0);
      expect(g.xOf(10, 0), 175, reason: '框在它真正的位置');
      // 整支用滿（剛匯入）：框＝整條
      final whole = SlipFilmGeometry(
        width: 350,
        height: 64,
        duration: 20,
        length: 20,
      );
      expect(whole.windowWidth, 350);
      expect(whole.restView(0), 0);
    });

    test('刻度至少隔 10 像素，長刻度落在整數倍上', () {
      SlipFilmGeometry g(double len) => SlipFilmGeometry(
        width: 350,
        height: 64,
        duration: 600,
        length: len,
      );
      expect(g(4).ticks, (minor: 0.5, major: 2.0));
      expect(g(1).ticks, (minor: 0.1, major: 0.5));
      expect(g(60).ticks, (minor: 5.0, major: 30.0));
    });

    test('扁的、瘦的原片：一格寬夾在高的一半到兩倍', () {
      SlipFilmGeometry g(double aspect) => SlipFilmGeometry(
        width: 350,
        height: 64,
        duration: 20,
        length: 4,
        aspect: aspect,
      );
      expect(g(16 / 9).tileWidth, closeTo(64 * 16 / 9, 1e-9));
      expect(g(4).tileWidth, 128);
      expect(g(0.2).tileWidth, 32);
      expect(SlipStrip.tileCount(350, aspect: 9 / 16), 23);
    });
  });

  testWidgets('大預覽在上、整支縮圖與膠卷在下；只寫起訖，沒有說明字', (t) async {
    await _open(t);
    final preview = t.getRect(_preview);
    expect(preview.height, greaterThan(350), reason: '進入換段就要是大預覽');
    expect(preview.bottom, lessThanOrEqualTo(t.getRect(_strip).top));
    expect(t.getRect(_strip).bottom, lessThan(t.getRect(_film).top));
    expect(t.getSize(_strip).height, SlipStrip.height);
    expect(t.getSize(_film).height, SlipFilm.height);
    expect(find.text('00:02.00 – 00:06.00'), findsOneWidget);
    expect(find.textContaining('拖動'), findsNothing);
    expect(find.textContaining('開頭'), findsNothing);
    expect(
      find.byKey(const ValueKey('slip-play')),
      findsNothing,
      reason: '沒有播放器就不擺播放鈕',
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('拖放大膠卷＝細調：框寬是片段長度，放手才提交', (t) async {
    final commits = <double>[];
    await _open(t, commit: commits.add);
    // 膠卷寬 350、框 140＝4 秒：一秒 35 像素。手指往左＝換成後面那段
    final g = await _dragFilm(t, -35, up: false);
    expect(commits, isEmpty, reason: '拖的過程不提交');
    expect(find.text('00:03.00 – 00:07.00'), findsOneWidget);
    await g.moveBy(const Offset(-35, 0));
    await t.pump();
    await g.up();
    await t.pump();
    expect(commits.single, closeTo(4, 1e-6));
    expect(find.text('00:04.00 – 00:08.00'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('膠卷夾在原片頭尾', (t) async {
    final commits = <double>[];
    await _open(t, commit: commits.add);
    await _dragFilm(t, 300);
    expect(commits.last, 0);
    await _dragFilm(t, -2000);
    expect(commits.last, 16);
    expect(find.text('00:16.00 – 00:20.00'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('整支排滿一條（片段超過原片四成）：拖的是框，框跟著手指走', (t) async {
    final commits = <double>[];
    await _open(t, start: 5, length: 10, commit: commits.add);
    final film = t.getRect(_film);
    // 一秒 17.5 像素：框在 5 秒的位置，兩邊都是原片的畫面
    expect(t.getRect(_window).left - film.left, closeTo(87.5, 0.5));
    expect(t.getRect(_window).width, closeTo(175, 0.5));
    // 手指往右 35 像素＝框往右 2 秒
    await _dragFilm(t, 35);
    expect(commits.last, closeTo(7, 1e-6));
    expect(t.getRect(_window).left - film.left, closeTo(122.5, 0.5));
    // 很短的原片也一樣：拖的是框，夾在頭尾
    await t.pumpWidget(const SizedBox());
    await _open(
      t,
      start: 0.05,
      duration: 0.35,
      length: 0.2,
      commit: commits.add,
    );
    await _dragFilm(t, 1000);
    expect(commits.last, closeTo(0.15, 1e-9));
    await _dragFilm(t, -1000);
    expect(commits.last, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets('片段貼著原片頭尾：剛進去左右都是畫面，不留空白', (t) async {
    // 使用者回報：18.31～35.18（貼著片尾）的片段，剛進去膠卷右邊一片空
    await _open(t, start: 16);
    final film = t.getRect(_film);
    expect(t.getRect(_window).right, closeTo(film.right, 0.5), reason: '框靠右');
    await t.pumpWidget(const SizedBox());
    await _open(t, start: 0);
    expect(t.getRect(_window).left, closeTo(t.getRect(_film).left, 0.5));
    expect(t.takeException(), isNull);
  });

  testWidgets('拖到原片外露出空白，放手滑回去：框靠過去、膠卷補滿', (t) async {
    final commits = <double>[];
    await _open(t, start: 8, commit: commits.add);
    final film = t.getRect(_film);
    expect(t.getRect(_window).left - film.left, closeTo(105, 0.5), reason: '置中');
    // 往左拖過頭：拖的時候框留在原地（膠卷跟著手指，右邊露出空白）
    final g = await _dragFilm(t, -1000, up: false);
    expect(t.getRect(_window).left - film.left, closeTo(105, 0.5));
    expect(find.text('00:16.00 – 00:20.00'), findsOneWidget);
    await g.up();
    await t.pump();
    expect(commits.last, 16);
    // 放手：膠卷滑回去（動畫），框靠到右邊
    await t.pump(const Duration(milliseconds: 300));
    expect(t.getRect(_window).right, closeTo(film.right, 0.5));
    expect(t.takeException(), isNull);
  });

  testWidgets('整支縮圖：點一下＝框的中間移到那裡，拖＝框跟著走', (t) async {
    final commits = <double>[];
    await _open(t, commit: commits.add);
    await _tapStrip(t, 10, 20);
    expect(commits.last, closeTo(8, 1e-6));
    expect(find.text('00:08.00 – 00:12.00'), findsOneWidget);
    // 點在最尾巴：夾住
    await _tapStrip(t, 19.9, 20);
    expect(commits.last, 16);
    // 往左拖四分之一條＝往前 5 秒
    final w = t.getSize(_strip).width;
    final g = await t.startGesture(t.getCenter(_strip));
    await g.moveBy(Offset(-w / 4, 0));
    await t.pump();
    await g.up();
    await t.pump();
    expect(commits.last, closeTo(11, 1e-6));
    expect(t.takeException(), isNull);
  });

  testWidgets('預覽是活的：預設不播、音量照片段；點一下循環播這一段', (t) async {
    usePlayer();
    await _open(t, playPath: '/v.work.mp4', volume: 0.6);
    expect(player.path, '/v.work.mp4');
    expect(player.playing, isFalse, reason: '一打開就出聲會嚇人');
    expect(player.volume, 0.6);
    expect(player.seeks.last, const Duration(seconds: 2), reason: '停在這段開頭');
    expect(find.byKey(const ValueKey('slip-play')), findsOneWidget);

    await t.tap(_preview);
    await t.pump();
    expect(player.playing, isTrue);
    // 播到段尾：下一個 tick 跳回段頭
    player.pos = const Duration(milliseconds: 5990);
    await t.pump(const Duration(milliseconds: 70));
    await t.pump();
    expect(player.seeks.last, const Duration(seconds: 2));
    // 再點一下停
    await t.tap(_preview);
    await t.pump();
    expect(player.playing, isFalse);
    await t.pumpWidget(const SizedBox());
    expect(player.disposed, isTrue);
  });

  testWidgets('拖膠卷時停播、畫面跟著換開頭；放手套用並從新開頭自動播', (t) async {
    usePlayer();
    final commits = <double>[];
    await _open(t, playPath: '/v.mp4', commit: commits.add);
    await t.tap(find.byKey(const ValueKey('slip-play')));
    await t.pump();
    expect(player.playing, isTrue);

    final g = await _dragFilm(t, -70, up: false);
    expect(player.playing, isFalse, reason: '拖的時候要停播');
    await t.pump(const Duration(milliseconds: 50));
    expect(
      player.seeks.last,
      const Duration(seconds: 4),
      reason: '畫面要跟著跳到新的開頭',
    );
    await g.up();
    await t.pump();
    await t.pump();
    expect(commits.single, closeTo(4, 1e-6));
    expect(player.playing, isTrue, reason: '放手就從新的開頭播');
    expect(player.seeks.last, const Duration(seconds: 4));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('點整支縮圖跳段：套用並從新開頭播', (t) async {
    usePlayer();
    final commits = <double>[];
    await _open(t, playPath: '/v.mp4', commit: commits.add);
    await _tapStrip(t, 15, 20);
    await t.pump();
    expect(commits.single, closeTo(13, 1e-6));
    expect(player.playing, isTrue);
    expect(player.seeks.last, const Duration(seconds: 13));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('播放器開不起來：退回開頭畫面，播放鈕收起來', (t) async {
    usePlayer(fail: true);
    await _open(
      t,
      playPath: '/v.mp4',
      load: (_) async => solidPng(255, 0, 0),
    );
    await t.pump();
    expect(player.disposed, isTrue);
    expect(find.byKey(const ValueKey('slip-play')), findsNothing);
    expect(_image, findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('沒有播放器時：一次只抽一張、最新開頭優先，關閉後不繼續抽圖', (t) async {
    final requests = <double>[];
    final jobs = <Completer<Uint8List?>>[];
    await _open(
      t,
      load: (s) {
        requests.add(s);
        final job = Completer<Uint8List?>();
        jobs.add(job);
        return job.future;
      },
    );
    expect(requests, [2]);
    await _tapStrip(t, 4.1, 20);
    await _tapStrip(t, 4.2, 20);
    expect(requests, [2], reason: '同時只能有一個解碼請求');
    jobs[0].complete(solidPng(255, 0, 0));
    await t.pump();
    expect(requests, [2, 2.2], reason: '略過中間的 2.1，只抽最新開頭');
    expect(_image, findsNothing, reason: '舊開頭的圖不能冒充新開頭');
    jobs[1].complete(solidPng(0, 255, 0));
    await t.pump();
    expect(_image, findsOneWidget);
    await _tapStrip(t, 4.3, 20);
    final count = requests.length;
    await t.pumpWidget(const SizedBox());
    jobs.last.complete(solidPng(0, 0, 255));
    await t.pump();
    expect(requests, hasLength(count));
    expect(t.takeException(), isNull);
  });

  testWidgets('縮圖跟大圖分開抽：膠卷先抽框附近的格子，整支縮圖最後', (t) async {
    final thumbs = <double>[];
    await _open(
      t,
      thumbnail: (s) async {
        thumbs.add(s);
        return solidPng(0, 255, 0);
      },
    );
    for (var i = 0; i < 40; i++) {
      await t.pump();
    }
    final g = SlipFilmGeometry(
      width: 350,
      height: 64,
      duration: 20,
      length: 4,
      aspect: 9 / 16,
    );
    final view = g.restView(2);
    final film = g.visibleTiles(view).length;
    final overview = SlipStrip.tileCount(350, aspect: 9 / 16);
    final keys = {
      for (final k in g.visibleTiles(view)) (g.tileTime(k) * 1000).round(),
      for (var i = 0; i < overview; i++)
        (SlipStrip.tileTime(i, overview, 20) * 1000).round(),
    };
    expect(thumbs, hasLength(keys.length), reason: '每一格只抽一次');
    // 第一張是框正中間（4 秒）附近那格
    expect((thumbs.first - 4).abs(), lessThan(g.step));
    final filmImages = find.descendant(of: _film, matching: find.byType(Image));
    expect(filmImages, findsNWidgets(film));
    expect(t.takeException(), isNull);
  });

  testWidgets('縮圖只要落在那一格代表的那一截裡：容差＝那一截的一半', (t) async {
    final asked = <double, double>{};
    await _open(
      t,
      tiles: (s, tolerance) async {
        asked[s] = tolerance;
        return solidPng(0, 255, 0);
      },
    );
    for (var i = 0; i < 40; i++) {
      await t.pump();
    }
    final g = SlipFilmGeometry(
      width: 350,
      height: 64,
      duration: 20,
      length: 4,
      aspect: 9 / 16,
    );
    // 膠卷第 3 格（框正中間附近）：一格 36/35 秒 → 容差一半
    final film = (g.tileTime(3) * 1000).round() / 1000;
    expect(asked[film], closeTo(g.step / 2, 1e-9));
    // 整支縮圖第 0 格：一格 20/23 秒
    final strip = (SlipStrip.tileTime(0, 23, 20) * 1000).round() / 1000;
    expect(asked[strip], closeTo(20 / 23 / 2, 1e-9));
    expect(t.takeException(), isNull);
  });

  testWidgets('解碼失敗顯示狀態；大字與小螢幕沒有溢位', (t) async {
    await _open(
      t,
      textScale: 1.5,
      load: (_) async => throw StateError('missing'),
    );
    t.view.physicalSize = const Size(320, 640);
    await t.pump();
    await t.pump();
    expect(find.text('無法預覽'), findsOneWidget);
    expect(t.takeException(), isNull);
    await _tapStrip(t, 4.1, 20);
    expect(find.text('00:02.10 – 00:06.10'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
