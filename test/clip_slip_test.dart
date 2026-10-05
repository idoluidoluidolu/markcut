// 換段（slip）：使用者要的「時間軸影片素材要能調整片段」——片段在時間軸
// 上的長度跟位置都不動，換成原片裡的另一段。
//
//   1. 選一段影片 → 工具列「換段」→ 大預覽（播這一段，用工作檔、照片段
//      音量）＋上面一條細的整支縮圖＋下面的放大膠卷，只寫起訖
//   2. 拖整支縮圖：框跟著走，放手才套用（trimStart／trimEnd 一起平移、
//      長度不變、offset 不變）；拖過頭會停在原片的頭尾
//   3. 拖放大膠卷：框固定在中間，拖一個框寬＝換一個片段長度（細調）
//   4. 換完一步「上一步」就回來；打開看看就關掉不算一步
//   5. 不是影片（文字…）或已經用到整支影片：按鈕灰掉、點了講為什麼
//   6. 「從影片提取聲音」拿進來的聲音也能換段（原片是影片檔，看得到
//      畫面）；純音訊檔沒有畫面可以對照，不給換
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/video_controller.dart';
import 'package:markcut/widgets/slip_film.dart';
import 'package:markcut/widgets/slip_picker.dart';
import 'package:markcut/widgets/slip_strip.dart';

import 'editor_harness.dart';

/// 一支 20 秒的影片，片段用 2～6 秒那一截，擺在時間軸 1 秒處；
/// 再一段文字（換段點不了它）
void _fill(TimelineModel m) {
  m.sources.add(
    MediaSource(
      path: '/v.mp4',
      name: 'v',
      kind: ClipKind.video,
      duration: 20,
      // 給工作檔＝不探 HDR、不碰檔案系統
      workPath: '/v.work.mp4',
    ),
  );
  m.clips.add(
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 2,
      trimEnd: 6,
      offset: 1,
      track: 0,
    ),
  );
  m.sources.add(
    MediaSource(path: '', name: 'hi', kind: ClipKind.text, duration: 3600),
  );
  m.clips.add(
    TimelineClip(
      id: 2,
      sourceIndex: 1,
      trimStart: 0,
      trimEnd: 3,
      offset: 0,
      track: 3,
    ),
  );
  // 從影片提取的聲音：來源是影片檔、種類是聲音（只用音軌）
  m.sources.add(
    MediaSource(path: '/a.mov', name: 'a', kind: ClipKind.audio, duration: 30),
  );
  m.clips.add(
    TimelineClip(
      id: 3,
      sourceIndex: 2,
      trimStart: 5,
      trimEnd: 9,
      offset: 0,
      track: 5,
    ),
  );
  // 純音訊檔
  m.sources.add(
    MediaSource(path: '/song.m4a', name: 'song', kind: ClipKind.audio, duration: 60),
  );
  m.clips.add(
    TimelineClip(
      id: 4,
      sourceIndex: 3,
      trimStart: 0,
      trimEnd: 4,
      offset: 0,
      track: 6,
    ),
  );
  m.ensureIdAbove(4);
}

/// 開空白編輯器、塞時間軸，等合成組起來（併批 350ms，走假時間）
Future<void> _open(WidgetTester t, FakeComp comp) async {
  await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
  await tick(t, 5);
  VideoEditorScreen.debugTimeline!(_fill);
  await tick(t, 15);
  expect(comp.builds, 1, reason: '合成播放器要組起來');
}

Finder get _strip => find.byKey(const ValueKey('slip-strip'));
Finder get _film => find.byKey(const ValueKey('slip-film'));

/// 換段大預覽的假播放器（測試主機沒有原生播放器）
class _FakePlayer implements PlayerX {
  _FakePlayer(this.path);

  @override
  final String path;
  double? volume;
  Duration pos = Duration.zero;
  bool playing = false;

  @override
  Future<void> initialize() async {}

  @override
  PlayerValueX get value => PlayerValueX(
    isInitialized: true,
    isPlaying: playing,
    duration: const Duration(seconds: 20),
    position: pos,
    size: const Size(1920, 1080),
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
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });
  // 假的原生合成播放器：預覽走合成那條路（跟實機一樣），不開 media_kit
  // 的單支播放器（測試主機沒有 libmpv）；也拿它數「換段有沒有重組合成」
  late FakeComp comp;
  final players = <_FakePlayer>[];
  setUp(() {
    players.clear();
    SlipPicker.debugPlayer = (p) {
      final player = _FakePlayer(p);
      players.add(player);
      return player;
    };
    SharedPreferences.setMockInitialValues({});
    Diag.reset();
    // 測試環境沒有真的原生 UiKitView：合成畫面走 Texture
    Diag.playerLayer.value = false;
    comp = FakeComp(TestWidgetsFlutterBinding.ensureInitialized())..install();
  });
  tearDown(() {
    comp.uninstall();
    SlipPicker.debugPlayer = null;
  });

  testWidgets('選影片 → 換段：拖框換一段，長度與位置不變；上一步回來', (t) async {
    await _open(t, comp);
    await t.tapAt(t.getCenter(clipBlock(1)));
    await settle(t, 6);
    await t.tap(find.text('換段'));
    await settle(t, 6);
    expect(_strip, findsOneWidget, reason: '沒有開出換段的縮圖帶');
    expect(_film, findsOneWidget, reason: '沒有開出放大膠卷');
    expect(find.text('00:02.00 – 00:06.00'), findsOneWidget);
    expect(find.textContaining('結尾'), findsNothing);
    expect(
      t.getSize(find.byKey(const ValueKey('slip-preview'))).height,
      greaterThan(350),
    );
    // 大預覽播工作檔（跟時間軸預覽同一份），音量照片段
    expect(players.map((p) => p.path), ['/v.work.mp4']);
    expect(players.single.volume, 1);
    expect(players.single.playing, isFalse, reason: '一打開就出聲會嚇人');
    // 打開看看還沒動：不是一個編輯步驟
    expect(undoEnabled(t), isFalse);

    // 往右拖四分之一條（整條＝20 秒）：框往後移，放手套用、重組合成
    final builds = comp.builds;
    final w = t.getSize(_strip).width;
    await t.drag(_strip, Offset(w / 4, 0));
    await settle(t, 6);
    // 合成的重組是併批的（350ms），而且等預覽跳到這段開頭的那次 seek 收完
    // 才做（手勢中不換畫面）：假時間走一段
    await tick(t, 40);
    final c = clipOf(t, 1);
    expect(c.trimStart, greaterThan(4), reason: '框沒有跟著往後');
    expect(comp.builds, greaterThan(builds), reason: '換段沒有重組合成');
    expect(c.trimEnd - c.trimStart, closeTo(4, 1e-9), reason: '長度不能變');
    expect(c.offset, 1, reason: '在時間軸上的位置不能變');
    expect(
      find.text('${_t(c.trimStart)} – ${_t(c.trimEnd)}'),
      findsOneWidget,
      reason: '起訖時間沒跟著換',
    );
    expect(players.single.playing, isTrue, reason: '放手就從新的開頭播');

    // 往右拖過頭：停在原片尾巴（16～20）
    await t.drag(_strip, Offset(w, 0));
    await settle(t, 6);
    expect(clipOf(t, 1).trimStart, closeTo(16, 1e-9));
    expect(clipOf(t, 1).trimEnd, closeTo(20, 1e-9));

    // 拖到最左邊，夾在原片起點＝0～4。
    await t.drag(_strip, Offset(-w, 0));
    await settle(t, 6);
    expect(clipOf(t, 1).trimStart, closeTo(0, 1e-9));
    expect(clipOf(t, 1).trimEnd, closeTo(4, 1e-9));

    // 關掉表、上一步：回到原本那一截
    await t.tap(find.text('完成'));
    await settle(t, 6);
    expect(undoEnabled(t), isTrue);
    await t.tap(undoButton());
    await settle(t, 6);
    expect(clipOf(t, 1).trimStart, closeTo(2, 1e-9));
    expect(clipOf(t, 1).trimEnd, closeTo(6, 1e-9));
    expect(t.takeException(), isNull);
    await settle(t, 40);
  });

  testWidgets('放大膠卷細調：拖一個框寬＝換一個片段長度', (t) async {
    await _open(t, comp);
    await t.tapAt(t.getCenter(clipBlock(1)));
    await settle(t, 6);
    await t.tap(find.text('換段'));
    await settle(t, 6);
    final window = t.getSize(_film).width * SlipFilmGeometry.windowFraction;
    // 手指往左＝換成後面那段：2～6 → 6～10
    await t.drag(_film, Offset(-window, 0));
    await settle(t, 6);
    await tick(t, 40);
    expect(clipOf(t, 1).trimStart, closeTo(6, 1e-6));
    expect(clipOf(t, 1).trimEnd, closeTo(10, 1e-6));
    expect(clipOf(t, 1).offset, 1);
    expect(find.text('00:06.00 – 00:10.00'), findsOneWidget);
    await t.tap(find.text('完成'));
    await settle(t, 40);
    expect(t.takeException(), isNull);
  });

  testWidgets('文字片段：換段灰掉，點了說只有影片可以換段', (t) async {
    await _open(t, comp);
    await t.tapAt(t.getCenter(clipBlock(2)));
    await settle(t, 6);
    await t.tap(find.text('換段'));
    await settle(t, 4);
    expect(_strip, findsNothing);
    expect(find.text('只有影片、從影片拿的聲音可以換段'), findsOneWidget);
    expect(find.byType(SlipStrip), findsNothing);
    await settle(t, 80);
    expect(t.takeException(), isNull);
  });

  testWidgets('從影片拿的聲音也能換段：長度與位置不變', (t) async {
    await _open(t, comp);
    await t.tapAt(t.getCenter(clipBlock(3)));
    await settle(t, 6);
    await t.tap(find.text('換段'));
    await settle(t, 6);
    expect(_strip, findsOneWidget, reason: '從影片拿的聲音沒有開出換段');
    expect(players.map((p) => p.path), ['/a.mov'], reason: '看得到原片畫面、聽得到聲音');
    final w = t.getSize(_strip).width;
    await t.drag(_strip, Offset(w / 4, 0));
    await settle(t, 6);
    await tick(t, 40);
    final c = clipOf(t, 3);
    expect(c.trimStart, greaterThan(5), reason: '框沒有跟著往後');
    expect(c.trimEnd - c.trimStart, closeTo(4, 1e-9), reason: '長度不能變');
    expect(c.offset, 0, reason: '在時間軸上的位置不能變');
    Navigator.of(t.element(_strip)).pop();
    await settle(t, 40);
    expect(t.takeException(), isNull);
  });

  testWidgets('純音訊檔：沒有畫面可以對照，換段灰掉', (t) async {
    await _open(t, comp);
    await t.tapAt(t.getCenter(clipBlock(4)));
    await settle(t, 6);
    await t.tap(find.text('換段'));
    await settle(t, 4);
    expect(_strip, findsNothing);
    expect(find.text('只有影片、從影片拿的聲音可以換段'), findsOneWidget);
    await settle(t, 80);
    expect(t.takeException(), isNull);
  });
}

/// 選段表保留百分之一秒，細調時看得出變化。
String _t(double sec) {
  final d = Duration(milliseconds: (sec * 1000).round());
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s.${((d.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0')}';
}
