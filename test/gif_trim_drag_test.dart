// GIF 頁的起訖竿子可以用手拖（使用者 10-12 定案：「要引導使用者拖曳
// 左右竿子來設起點終點」，戊案：縮圖帶壓暗＋「拖兩邊的竿子選取範圍」，
// 竿子不要圓點、一拖動引導就消失；按鈕改「設為起點／設為終點」）。
//
// 修剪條（GifTrimStrip 有接竿子回呼的時候）：
//   1. 手指落在竿子附近（線沒對準也行）拖＝拖那一根，竿子不跳到手指下面
//   2. 其他地方拖＝播放頭，起訖點不動
//   3. 兩根貼在一起：往左拖是起點、往右拖是終點——拉近之後一定拉得開
//      （以前三個熱區互搶，使用者回報「拉近就再也拉不開」）
//   4. 竿子頂到另一根就停（留最短長度）、拉得到影片頭尾
//   5. 引導只畫、不擋手勢
// GIF 頁：
//   6. 新的一支：縮圖帶上有引導、按鈕是「設為起點／設為終點」；只點一下
//      引導還在，一拖竿子引導就消失、起點真的變了
//   7. 按「設為終點」也收掉引導；續作的草稿已經設過範圍就不蓋引導
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/gif_screen.dart';
import 'package:markcut/services/gif_trim_range.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/video_controller.dart';
import 'package:markcut/widgets/gif_trim_strip.dart';

const double kDur = 30;
const double kStripW = 300; // 1px = 0.1 秒

/// 照 GifScreen 的接法把修剪條接起來（竿子跟手、頂到另一根就停）
class _Host extends StatefulWidget {
  const _Host({this.start = 10, this.end = 20, this.hint = false});

  final double start;
  final double end;
  final bool hint;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late double start = widget.start;
  late double end = widget.end;
  final pos = ValueNotifier<double>(12);
  double? _from;
  double _acc = 0;
  TrimEdge? edge;
  double _grab = 0;
  final events = <String>[];

  @override
  void dispose() {
    pos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(
        width: kStripW,
        child: GifTrimStrip(
          dur: kDur,
          start: start,
          end: end,
          pos: pos,
          cells: List<Uint8List?>.filled(10, null),
          hint: widget.hint,
          onTapAt: (t) {
            events.add('tap');
            pos.value = t;
          },
          onScrubStart: (t) {
            events.add('scrubStart');
            _from = t;
            _acc = 0;
            pos.value = t;
          },
          onScrubBy: (dt) {
            final f = _from;
            if (f == null) return;
            _acc += dt;
            pos.value = (f + _acc).clamp(0.0, kDur);
          },
          onScrubEnd: () => _from = null,
          onEdgeStart: (e, t) {
            events.add('edge:${e.name}');
            edge = e;
            _grab = (e == TrimEdge.start ? start : end) - t;
          },
          onEdgeMove: (t) {
            final e = edge;
            if (e == null) return;
            setState(() {
              if (e == TrimEdge.start) {
                start = (t + _grab).clamp(0.0, end - kTrimMinGap);
                pos.value = start;
              } else {
                end = (t + _grab).clamp(start + kTrimMinGap, kDur);
                pos.value = end;
              }
            });
          },
          onEdgeEnd: () {
            events.add('edgeEnd');
            edge = null;
          },
        ),
      ),
    ),
  );
}

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

const _ffmpegEvents = 'flutter.arthenica.com/ffmpeg_kit_event';

void main() {
  Offset at(WidgetTester t, double x) {
    final r = t.getRect(find.byType(GifTrimStrip));
    return Offset(r.left + x, r.center.dy);
  }

  /// 從修剪條的 [fromX] 下手，分兩段拖 [dx] px 之後放開
  Future<void> drag(WidgetTester t, Offset from, double dx) async {
    final g = await t.startGesture(from);
    await t.pump();
    await g.moveBy(Offset(dx / 2, 0));
    await t.pump();
    await g.moveBy(Offset(dx / 2, 0));
    await t.pump();
    await g.up();
    await t.pump();
  }

  Future<_HostState> pumpHost(
    WidgetTester t, {
    double start = 10,
    double end = 20,
    bool hint = false,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        home: _Host(start: start, end: end, hint: hint),
      ),
    );
    return t.state<_HostState>(find.byType(_Host));
  }

  group('修剪條：竿子可以拖', () {
    testWidgets('手指落在起點竿子右邊 10px 往左拖 50px：起點跟著走 5 秒、不跳、終點不動', (t) async {
      final h = await pumpHost(t);
      await drag(t, at(t, 110), -50);
      expect(h.events, contains('edge:start'));
      expect(h.events, isNot(contains('scrubStart')), reason: '抓到竿子就不是播放頭');
      expect(h.start, closeTo(5, 0.01), reason: '竿子跟手指一樣走 50px，不先跳到手指下面');
      expect(h.end, 20);
      expect(h.pos.value, closeTo(5, 0.01), reason: '指針跟著竿子，看得到剪點');
      expect(h.events.last, 'edgeEnd');
    });

    testWidgets('終點竿子左邊 5px 往右拖 40px：終點 +4 秒', (t) async {
      final h = await pumpHost(t);
      await drag(t, at(t, 195), 40);
      expect(h.events, contains('edge:end'));
      expect(h.end, closeTo(24, 0.01));
      expect(h.start, 10);
    });

    testWidgets('離竿子遠的地方拖：是播放頭，起訖點不動', (t) async {
      final h = await pumpHost(t);
      await drag(t, at(t, 150), 30);
      expect(h.events, contains('scrubStart'));
      expect(h.events.where((e) => e.startsWith('edge')), isEmpty);
      expect(h.pos.value, closeTo(18, 0.01));
      expect((h.start, h.end), (10.0, 20.0));
    });

    testWidgets('兩根貼在一起：往左拖動的是起點、往右拖動的是終點', (t) async {
      var h = await pumpHost(t, start: 15, end: 15.2);
      await drag(t, at(t, 151), -40);
      expect(h.events, contains('edge:start'));
      expect(h.start, closeTo(11, 0.05));
      expect(h.end, 15.2);

      await t.pumpWidget(const SizedBox());
      h = await pumpHost(t, start: 15, end: 15.2);
      await drag(t, at(t, 151), 40);
      expect(h.events, contains('edge:end'));
      expect(h.end, closeTo(19.2, 0.05));
      expect(h.start, 15);
    });

    testWidgets('拉近就拉不開（使用者回報過）：終點拉到頂住起點、放手，再往右拉一定拉得開', (t) async {
      final h = await pumpHost(t);
      await drag(t, at(t, 200), -110);
      expect(h.end, closeTo(10 + kTrimMinGap, 1e-9), reason: '頂到起點就停、留最短長度');
      expect(h.start, 10, reason: '不推著起點走');

      await drag(t, at(t, 103), 60);
      expect(h.end, greaterThan(15), reason: '貼在一起之後往右拉是終點，拉得開');
      expect(h.start, 10);
    });

    testWidgets('起點拖過頭：停在終點前面；手指抓偏也拉得到影片開頭', (t) async {
      final h = await pumpHost(t);
      await drag(t, at(t, 100), 200);
      expect(h.start, closeTo(20 - kTrimMinGap, 1e-9));

      await t.pumpWidget(const SizedBox());
      final h2 = await pumpHost(t);
      // 抓在竿子右邊 15px（比竿子晚 1.5 秒），手指拖到修剪條外面
      await drag(t, at(t, 115), -140);
      expect(h2.start, 0, reason: '竿子要拉得到 0 秒');
    });

    testWidgets('引導蓋在上面也照樣拖得動竿子', (t) async {
      final h = await pumpHost(t, hint: true);
      expect(find.text(GifTrimStrip.hintText), findsOneWidget);
      await drag(t, at(t, 100), 30);
      expect(h.start, closeTo(13, 0.01));
    });
  });

  group('GIF 頁', () {
    late Directory dir;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      dir = Directory.systemTemp.createTempSync('gif_drag_');
      final m =
          TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
      m.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => dir.path,
      );
      m.setMockMethodCallHandler(
        const MethodChannel(_ffmpegEvents),
        (_) async => null,
      );
      GifScreen.debugPlayer = _FakePlayer.new;
      // 預覽永遠做不完：這裡只看修剪條
      GifScreen.debugMakeGif =
          ({
            required String inputPath,
            required double start,
            required double end,
            required int fps,
            required int maxSide,
            Rect? crop,
            double speed = 1.0,
          }) => Completer<String?>().future;
    });

    tearDown(() {
      GifScreen.debugPlayer = null;
      GifScreen.debugMakeGif = null;
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        ..setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        )
        ..setMockMethodCallHandler(const MethodChannel(_ffmpegEvents), null);
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> open(WidgetTester t, {Map<String, dynamic>? restore}) async {
      await t.pumpWidget(
        MaterialApp(
          home: GifScreen(path: 'v.mp4', name: 'v.mp4', restore: restore),
        ),
      );
      for (
        var i = 0;
        i < 40 && find.byType(GifTrimStrip).evaluate().isEmpty;
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 20));
      }
      expect(find.byType(GifTrimStrip), findsOneWidget, reason: '頁面要開得起來');
    }

    GifTrimStrip strip(WidgetTester t) =>
        t.widget<GifTrimStrip>(find.byType(GifTrimStrip));

    testWidgets('新的一支：有引導、按鈕是「設為起點／設為終點」；點一下引導還在，一拖竿子就消失', (t) async {
      await open(t);
      expect(find.text(GifTrimStrip.hintText), findsOneWidget);
      expect(find.text('設為起點'), findsOneWidget);
      expect(find.text('設為終點'), findsOneWidget);
      expect(find.text('設起點'), findsNothing);
      expect((strip(t).start, strip(t).end), (0.0, 10.0));

      // 只點一下：跳指針，引導還在
      final r = t.getRect(find.byType(GifTrimStrip));
      await t.tapAt(Offset(r.left + r.width / 2, r.center.dy));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text(GifTrimStrip.hintText), findsOneWidget);

      // 抓起點竿子（在最左邊）往右拖四分之一條＝2.5 秒
      await drag(t, Offset(r.left + 4, r.center.dy), r.width / 4);
      await t.pump(const Duration(milliseconds: 100));
      expect(
        find.text(GifTrimStrip.hintText),
        findsNothing,
        reason: '一拖動引導就消失',
      );
      expect(strip(t).start, closeTo(2.5, 0.05));
      expect(strip(t).end, 10);
      expect(t.takeException(), isNull);
    });

    testWidgets('按「設為終點」也收掉引導', (t) async {
      await open(t);
      expect(find.text(GifTrimStrip.hintText), findsOneWidget);
      await t.tap(find.text('設為終點'));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text(GifTrimStrip.hintText), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('續作的草稿已經設過範圍：不蓋引導', (t) async {
      await open(t, restore: {'start': 2.0, 'end': 5.0});
      expect((strip(t).start, strip(t).end), (2.0, 5.0));
      expect(find.text(GifTrimStrip.hintText), findsNothing);
      expect(t.takeException(), isNull);
    });
  });
}
