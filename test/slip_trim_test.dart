// 換段表直接改長度（使用者：「換段要可以直接裁剪長度」）：
//   1. 放大膠卷的框兩邊有把手（跟時間軸的黃色修剪把手同一個樣子）
//   2. 拉右邊＝改結尾、拉左邊＝改開頭；拉的時候膠卷不動、比例不變，只有
//      那條邊跟著手指，起訖時間跟著跳；放手才提交，框放回中間四成寬
//   3. 夾在原片頭尾；最短留一截
//   4. 拉的時候停播，大預覽停在拉的那條邊；放手從新的開頭播
//   5. 從框的中間拖照舊是換段（長度不變）
//   6. 沒給改長度的回呼：沒有把手，框邊拖下去也是換段
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/video_controller.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/slip_film.dart';
import 'package:markcut/widgets/slip_picker.dart';

Finder get _film => find.byKey(const ValueKey('slip-film'));
Finder get _left => find.byKey(const ValueKey('slip-trim-left'));
Finder get _right => find.byKey(const ValueKey('slip-trim-right'));

/// 假播放器：20 秒，記下 seek 與播放狀態
class _FakePlayer implements PlayerX {
  _FakePlayer(this.path);

  @override
  final String path;
  bool playing = false;
  Duration pos = Duration.zero;
  final seeks = <Duration>[];

  @override
  Future<void> initialize() async {}

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
  Future<void> setVolume(double v) async {}

  @override
  Future<void> setPlaybackSpeed(double s) async {}

  @override
  Future<void> setLooping(bool loop) async {}

  @override
  void dispose() {}

  @override
  Widget view({Key? key}) => ColoredBox(key: key, color: Colors.blueGrey);

  @override
  String get debugInfo => 'fake';
}

void main() {
  final ranges = <(double, double)>[];
  final slides = <double>[];
  late _FakePlayer player;

  setUp(() {
    ranges.clear();
    slides.clear();
  });
  tearDown(() => SlipPicker.debugPlayer = null);

  Future<void> open(
    WidgetTester t, {
    double start = 2,
    double length = 4,
    bool trimmable = true,
    String? playPath,
    double minLength = 0,
  }) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          splashFactory: InkRipple.splashFactory,
        ),
        home: Scaffold(
          backgroundColor: kBg,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: 0.88,
              child: SlipPicker(
                duration: 20,
                start: start,
                length: length,
                playPath: playPath,
                aspect: 9 / 16,
                minLength: minLength,
                loadFrame: (_) async => null,
                loadThumbnail: (_) async => null,
                onCommit: slides.add,
                onCommitRange: trimmable
                    ? (s, l) => ranges.add((s, l))
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
  }

  /// 框寬（像素）：放大膠卷寬度的四成
  double window(WidgetTester t) =>
      t.getSize(_film).width * SlipFilmGeometry.windowFraction;

  /// 按住把手拖 [dx]，[up]＝放手
  Future<TestGesture> dragHandle(
    WidgetTester t,
    Finder handle,
    double dx, {
    bool up = true,
  }) async {
    final g = await t.startGesture(t.getCenter(handle));
    await g.moveBy(Offset(dx, 0));
    await t.pump();
    if (up) {
      await g.up();
      await t.pump();
    }
    return g;
  }

  testWidgets('框兩邊有把手；拉右邊＝加長：只有那條邊跟著手指，膠卷不動，放手才提交', (t) async {
    await open(t);
    expect(_left, findsOneWidget);
    expect(_right, findsOneWidget);
    final w = window(t);
    final leftX = t.getRect(_left).left;
    final rightX = t.getRect(_right).right;
    expect(rightX - leftX, closeTo(w, 0.5));

    // 半個框寬＝片段長度的一半：4 秒 → 6 秒
    final g = await dragHandle(t, _right, w / 2, up: false);
    expect(ranges, isEmpty, reason: '拉的過程不提交（提交要重組合成）');
    expect(t.getRect(_left).left, closeTo(leftX, 0.5), reason: '左邊不能跟著動');
    expect(t.getRect(_right).right, closeTo(rightX + w / 2, 0.5));
    expect(find.text('00:02.00 – 00:08.00'), findsOneWidget);
    await g.up();
    await t.pump();
    expect(ranges, hasLength(1));
    expect(ranges.single.$1, closeTo(2, 1e-6));
    expect(ranges.single.$2, closeTo(6, 1e-6));
    expect(slides, isEmpty, reason: '改長度不是換段');
    // 放手：框放回中間四成寬（膠卷照新長度重新縮放）
    expect(t.getRect(_left).left, closeTo(leftX, 0.5));
    expect(t.getRect(_right).right, closeTo(rightX, 0.5));
    expect(find.text('00:02.00 – 00:08.00'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('拉左邊＝從前面剪短：結尾不動', (t) async {
    await open(t);
    // 四分之一個框寬＝1 秒：2～6 → 3～6
    await dragHandle(t, _left, window(t) / 4);
    expect(ranges.single.$1, closeTo(3, 1e-6));
    expect(ranges.single.$2, closeTo(3, 1e-6));
    expect(find.text('00:03.00 – 00:06.00'), findsOneWidget);
  });

  testWidgets('夾在原片頭尾，最短留一截', (t) async {
    await open(t, start: 14, length: 4);
    // 右邊往外拉過頭：停在原片尾巴 20 秒
    await dragHandle(t, _right, 1000);
    expect(ranges.last.$1, closeTo(14, 1e-6));
    expect(ranges.last.$1 + ranges.last.$2, closeTo(20, 1e-6));
    // 左邊往外拉過頭：停在 0 秒
    await dragHandle(t, _left, -2000);
    expect(ranges.last.$1, closeTo(0, 1e-6));
    expect(ranges.last.$1 + ranges.last.$2, closeTo(20, 1e-6));
    // 右邊往裡拉過頭：最短也留一截（框至少 24 像素寬），不會變成 0 或負的
    await dragHandle(t, _right, -2000);
    final pps = window(t) / 20;
    expect(ranges.last.$1, closeTo(0, 1e-6));
    expect(
      ranges.last.$2,
      closeTo(SlipFilm.minWindowPx / pps, 1e-6),
      reason: '最短＝框剩 24 像素',
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('拉的時候停播、大預覽停在拉的那條邊；放手從新的開頭播', (t) async {
    SlipPicker.debugPlayer = (p) => player = _FakePlayer(p);
    await open(t, playPath: '/v.mp4');
    await t.tap(find.byKey(const ValueKey('slip-play')));
    await t.pump();
    expect(player.playing, isTrue);
    final g = await dragHandle(t, _right, window(t) / 4, up: false);
    // 拖曳中的 seek 有節流（最多每 40ms 一次）：等它送完
    await t.pump(const Duration(milliseconds: 100));
    expect(player.playing, isFalse, reason: '拉框邊要先停播');
    // 拉右邊：停在新結尾的最後一格（7 秒前一格）
    expect(player.seeks.last.inMilliseconds, closeTo(7000 - 33, 2));
    await g.up();
    await t.pump();
    await t.pump();
    expect(player.playing, isTrue, reason: '放手從新的開頭播');
    expect(player.seeks.last, const Duration(seconds: 2));
  });

  testWidgets('從框的中間拖照舊是換段（長度不變）', (t) async {
    await open(t);
    final g = await t.startGesture(t.getCenter(_film));
    await g.moveBy(Offset(-window(t), 0));
    await t.pump();
    await g.up();
    await t.pump();
    expect(ranges, isEmpty);
    expect(slides.single, closeTo(6, 1e-6));
    expect(find.text('00:06.00 – 00:10.00'), findsOneWidget);
  });

  testWidgets('沒給改長度的回呼：沒有把手，框邊拖下去也是換段', (t) async {
    await open(t, trimmable: false);
    expect(_left, findsNothing);
    expect(_right, findsNothing);
    final film = t.getRect(_film);
    // 按在右框邊上往右拖四分之一框寬＝換成前面那段（手指往右＝往前）
    final edge = Offset(film.left + film.width * 0.7, film.center.dy);
    final g = await t.startGesture(edge);
    await g.moveBy(Offset(window(t) / 4, 0));
    await t.pump();
    await g.up();
    await t.pump();
    expect(ranges, isEmpty);
    expect(slides.single, closeTo(1, 1e-6));
  });
}
