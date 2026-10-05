// 從影片挑一段聲音（AudioPickScreen）：使用者要「可以看影片選音訊的
// UI，不然純音訊用眼睛看不出要選的段落」。
//
//   1. 預設整支、進來先不播；聲音不靜音（挑的就是聲音）
//   2. 縮圖帶點哪跳哪，「設起點」「設終點」照白針的位置設（跟 GIF 製作
//      同一套規矩）
//   3. 「加入音訊」回傳選的範圍；返回＝不加（null）
//   4. 播放一律播選的那一段：播到段尾跳回起點
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/audio_pick_screen.dart';
import 'package:markcut/services/gif_trim_range.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/video_controller.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_trim_strip.dart';

import 'editor_harness.dart' show mockEditorPlugins;

/// 假播放器：十秒、160×90，記下有沒有被靜音
class _FakePlayer implements PlayerX {
  _FakePlayer(this.path);

  @override
  final String path;
  bool playing = false;
  Duration pos = Duration.zero;
  double? volume;
  final seeks = <Duration>[];

  @override
  Future<void> initialize() async {}

  @override
  PlayerValueX get value => PlayerValueX(
    isInitialized: true,
    isPlaying: playing,
    duration: const Duration(seconds: 10),
    position: pos,
    size: const Size(160, 90),
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
  void dispose() {}

  @override
  Widget view({Key? key}) => ColoredBox(key: key, color: Colors.blueGrey);

  @override
  String get debugInfo => 'fake';
}

void main() {
  late _FakePlayer player;
  // 縮圖帶會去叫系統抽幀／FFmpeg：測試主機沒有，擋掉
  setUpAll(() => mockEditorPlugins(TestWidgetsFlutterBinding.ensureInitialized()));
  setUp(() {
    AudioPickScreen.debugPlayer = (p) => player = _FakePlayer(p);
  });
  tearDown(() => AudioPickScreen.debugPlayer = null);

  /// 從一個按鈕推出挑段落那一頁，回傳「拿到的結果」的盒子
  Future<List<TrimRange?>> open(WidgetTester t) async {
    final got = <TrimRange?>[];
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => got.add(
              await Navigator.push<TrimRange>(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      const AudioPickScreen(path: '/v.mp4', name: 'v.mp4'),
                ),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    return got;
  }

  /// 點縮圖帶上第 [frac] 的位置（0～1）
  Future<void> tapStrip(WidgetTester t, double frac) async {
    final r = t.getRect(find.byType(GifTrimStrip));
    await t.tapAt(Offset(r.left + r.width * frac, r.center.dy));
    await t.pump();
  }

  testWidgets('預設整支、先不播、不靜音；設起訖點後加入回傳那一段', (t) async {
    final got = await open(t);
    expect(find.text('長度 10.0 秒'), findsOneWidget, reason: '預設要是整支');
    expect(player.playing, isFalse, reason: '一進來就出聲會嚇人');
    expect(player.volume, isNot(0.0), reason: '挑的是聲音，不能像 GIF 那樣靜音');

    await tapStrip(t, 0.3);
    await t.tap(find.text('設起點'));
    await t.pump();
    await tapStrip(t, 0.8);
    await t.tap(find.text('設終點'));
    await t.pump();
    expect(find.text('長度 5.0 秒'), findsOneWidget);

    await t.tap(find.text('加入音訊'));
    await t.pumpAndSettle();
    expect(got, hasLength(1));
    expect(got.single!.start, closeTo(3, 0.05));
    expect(got.single!.end, closeTo(8, 0.05));
    expect(t.takeException(), isNull);
  });

  testWidgets('返回＝不加', (t) async {
    final got = await open(t);
    await t.pageBack();
    await t.pumpAndSettle();
    expect(got, [null]);
  });

  testWidgets('播放播的是選的那一段：播到段尾跳回起點', (t) async {
    await open(t);
    await tapStrip(t, 0.2);
    await t.tap(find.text('設起點'));
    await t.pump();
    await tapStrip(t, 0.5);
    await t.tap(find.text('設終點'));
    await t.pump();
    // 指針停在段尾：按播放＝從起點播
    await t.tap(find.byIcon(Icons.play_arrow_rounded));
    await t.pump();
    expect(player.playing, isTrue);
    expect(player.pos.inMilliseconds, closeTo(2000, 60));
    // 播到段尾：下一個 tick 跳回起點
    player.pos = const Duration(milliseconds: 4990);
    await t.pump(const Duration(milliseconds: 150));
    await t.pump();
    expect(player.pos.inMilliseconds, closeTo(2000, 60));
    await t.pumpWidget(const SizedBox());
  });
}
