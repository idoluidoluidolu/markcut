// 快速 Vlog：走真的編輯頁（首頁「快速 Vlog」挑好的那一批 → videoPaths＋
// vlogEntry，跟使用者的路一樣），中繼資料探測由假通道回。
//
// 使用者 11-07：「丟一堆影片進去、各取兩秒（預設）、可以調整時間跟段落、
// 串成一部；也可以個別調整影片長度，不卡死全部都要共同秒數」；畫布選甲
// ＝原本的剪輯畫面，左上多一顆「每段 N 秒」。
// 11-08：「要有地方能一次調整整體秒數，例如全部改成 0.5 秒一個」——原本那顆
// 太不明顯；畫布再選甲：放大、選著一段時旁邊另外多一顆「這段」，秒數表加快選。
// 11-09：「直接不用螢幕上方那個，在黑色這裡顯示每段的秒數控制，點選 clip 後
// 改成該段的秒數控制」——膠囊跟秒數表都拿掉，時間軸底下一條控制列一直開著。
//
// 守的是：
// - 進場每支取中間 2 秒、不到 2 秒整支、照挑選順序頭尾接；時間軸底下
//   （工具列上面）「每段 2 秒」；不帶預設浮水印字；緊接開著
// - 改每段：每一段都變（個別改過的也一起）、整軌接齊；時間軸片段右下角標秒數
// - 點一段：控制列變成「這段」（琥珀），只改那段；點空白回到每段
// - 快選：每段按 0.5 全部變 0.5；這段原片給不起的灰掉、按了說最長幾秒
// - 快選來回換：取的那一截不會一路偏掉（兩次之間沒別的改動就照原本那一截算）
// - 上一步：按一次快選、拖一次滑桿各一步，片段長度跟每段的秒數一起退回去
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/slip_picker.dart';
import 'package:markcut/widgets/timeline_editor.dart';

import 'editor_harness.dart';

late Directory _dir;

/// 三支「影片」的長度：長、短（不到 2 秒）、中
const _videos = <String, double>{'a.mp4': 10.0, 'b.mp4': 1.2, 'c.mp4': 6.0};

String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

TimelineModel _tl() {
  late TimelineModel out;
  VideoEditorScreen.debugTimeline!((tl) => out = tl);
  return out;
}

List<TimelineClip> _lane() => _tl().onTrack(0);

void _expectContiguous() {
  var at = 0.0;
  for (final c in _lane()) {
    expect(c.offset, closeTo(at, 1e-6), reason: '片段 ${c.id} 要接在前一段後面');
    at = c.end;
  }
}

/// 時間軸片段上秒數標的顏色（同一個字可能好幾段）
List<Color?> _tagColors(String label) => [
  for (final e in find.text(label).evaluate()) (e.widget as Text).style?.color,
];

/// 控制列左欄上面那個字（「每段」／「這段」）
Text _label(WidgetTester t) =>
    t.widget<Text>(find.byKey(const ValueKey('vlog-bar-label')));

/// 控制列左欄的秒數
String? _sec(WidgetTester t) =>
    t.widget<Text>(find.byKey(const ValueKey('vlog-bar-sec'))).data;

/// 按控制列上的快選
Future<void> _preset(WidgetTester t, String label) async {
  await t.tap(find.byKey(ValueKey('vlog-preset-$label')));
  await settle(t, 6);
}

/// 照手指拖滑桿的順序叫：按下、拖到 [to]、放開
Future<void> _slide(WidgetTester t, double to) async {
  final s = t.widget<Slider>(find.byKey(const ValueKey('vlog-bar-slider')));
  s.onChangeStart?.call(s.value);
  s.onChanged!(to);
  s.onChangeEnd!(to);
  await settle(t, 6);
}

Future<void> _select(WidgetTester t, int id) async {
  editorOf(t).onSelect(id);
  await settle(t, 6);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
  });

  tearDownAll(() {
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('markcut_quick_vlog_');
    for (final n in _videos.keys) {
      File(_p(n)).writeAsStringSync('video $n');
    }
    WorkFiles.supportDirOverride = _dir;
    WorkFiles.holdSweep = false;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    mockEditorPlugins(b, tempDir: _dir);
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/prep'),
      (call) async {
        switch (call.method) {
          case 'available':
            return true;
          case 'probeLite':
            final name = (call.arguments as String)
                .split(Platform.pathSeparator)
                .last;
            final dur = _videos[name];
            if (dur == null) return null;
            return <String, dynamic>{
              'w': 1920,
              'h': 1080,
              'codec': 'avc1',
              'rotated': false,
              'sdr709': true,
              'durSec': dur,
            };
          case 'probe':
            return <String, dynamic>{
              'frames': 300,
              'keyframes': 60,
              'maxGopFrames': 6,
            };
        }
        return null;
      },
    );
  });

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(
          videoPaths: [for (final n in _videos.keys) _p(n)],
          vlogEntry: true,
        ),
      ),
    );
    await settle(t, 60);
  }

  /// 先真的離開編輯頁，再讓背景工作讀到 mounted=false（同 import_order_test）
  Future<void> drain(WidgetTester t) async {
    await t.pumpWidget(const SizedBox.shrink());
    expect(VideoEditorScreen.debugTimeline, isNull);
    await t.pump(const Duration(seconds: 3));
    await t.pump(const Duration(seconds: 3));
  }

  testWidgets('進場：每支取中間 2 秒、不到 2 秒整支、照順序接；時間軸底下每段 2 秒', (t) async {
    await open(t);
    final lane = _lane();
    expect(
      [for (final c in lane) _tl().sourceOf(c).path],
      [for (final n in _videos.keys) _p(n)],
      reason: '照挑選順序',
    );
    expect(lane[0].trimStart, closeTo(4, 1e-6), reason: '10 秒取中間 4~6');
    expect(lane[0].trimEnd, closeTo(6, 1e-6));
    expect(lane[1].trimStart, 0, reason: '不到 2 秒整支');
    expect(lane[1].trimEnd, closeTo(1.2, 1e-6));
    expect(lane[2].trimStart, closeTo(2, 1e-6), reason: '6 秒取中間 2~4');
    expect(lane[2].trimEnd, closeTo(4, 1e-6));
    _expectContiguous();
    expect(_tl().duration, closeTo(5.2, 1e-6));

    expect(_label(t).data, '每段');
    expect(_label(t).style?.color, Colors.white);
    expect(_sec(t), '2');
    // 擺在時間軸那塊空白的下面、工具列上面——預覽上不再疊任何東西
    final bar = t.getRect(find.byKey(const ValueKey('vlog-bar')));
    final tracks = t.getRect(find.byType(TimelineEditor));
    expect(bar.top, greaterThanOrEqualTo(tracks.bottom), reason: '在軌道下面');
    expect(
      bar.bottom,
      lessThanOrEqualTo(t.getRect(find.text('切割')).top),
      reason: '在工具列上面',
    );
    // 片段右下角標秒數，都跟著每段走＝白字
    expect(_tagColors('2.0s'), [kText, kText]);
    expect(_tagColors('1.2s'), [kText]);
    // 不帶預設浮水印字（同馬賽克、去背的入口）
    expect(find.text('@我的浮水印'), findsNothing);
    // 緊接開著：工具列那顆是琥珀色
    final tidy = t.widget<Icon>(
      find.descendant(
        of: find.ancestor(of: find.text('緊接'), matching: find.byType(InkWell)),
        matching: find.byType(Icon),
      ),
    );
    expect(tidy.color, kSelect, reason: '快速 Vlog 一律緊接');
    await drain(t);
  });

  testWidgets('改每段：拖滑桿每段都變長、短的維持整支，整軌接齊', (t) async {
    await open(t);
    await _slide(t, 3);
    expect(_sec(t), '3', reason: '左欄秒數跟著變');
    final lane = _lane();
    expect(lane[0].length, closeTo(3, 1e-6));
    expect(lane[0].trimStart, closeTo(3.5, 1e-6), reason: '中心不動');
    expect(lane[1].length, closeTo(1.2, 1e-6), reason: '原片只有 1.2 秒');
    expect(lane[2].length, closeTo(3, 1e-6));
    _expectContiguous();
    expect(_tagColors('3.0s'), [kText, kText]);
    await drain(t);
  });

  testWidgets('點一段：控制列變成這段，只改它；點空白回到每段，快選全部一起改', (t) async {
    await open(t);
    final first = _lane()[0];
    await _select(t, first.id);
    expect(_label(t).data, '這段', reason: '點選 clip 後改成該段的秒數控制');
    expect(_label(t).style?.color, kSelect, reason: '跟時間軸的選取框同色');
    expect(_sec(t), '2');
    await _slide(t, 4.5);
    var lane = _lane();
    expect(lane[0].length, closeTo(4.5, 1e-6));
    expect(lane[2].length, closeTo(2, 1e-6), reason: '別段不動');
    _expectContiguous();
    expect(_sec(t), '4.5');
    expect(_tagColors('4.5s'), [kSelect], reason: '個別改過的段標琥珀字');

    // 點空白取消選取：回到每段（秒數是每段的 2，不是剛剛那段的 4.5）
    await _select(t, -1);
    expect(_label(t).data, '每段');
    expect(_sec(t), '2');

    // 按現在選著的 2 也照套：個別改過的一起改回來
    await _preset(t, '2');
    lane = _lane();
    expect(lane[0].length, closeTo(2, 1e-6), reason: '按 2 也要把自訂的改回 2');
    _expectContiguous();
    expect(_tagColors('2.0s'), [kText, kText], reason: '改回來就是跟著每段走');
    expect(find.text('4.5s'), findsNothing);

    // 全部改成 0.5 秒一個（使用者舉的例子）
    await _preset(t, '0.5');
    expect(_sec(t), '0.5');
    lane = _lane();
    for (final c in lane) {
      expect(c.length, closeTo(0.5, 1e-6), reason: '每一段都 0.5，原片短的也一樣');
    }
    expect(lane[0].trimStart, closeTo(4.75, 1e-6), reason: '中心不動');
    _expectContiguous();
    expect(_tl().duration, closeTo(1.5, 1e-6));

    // 再點那段：這段 0.5
    await _select(t, first.id);
    expect(_label(t).data, '這段');
    expect(_sec(t), '0.5');
    await drain(t);
  });

  testWidgets('這段：原片給不起的快選灰掉，按了說最長幾秒', (t) async {
    await open(t);
    final short = _lane()[1]; // 原片 1.2 秒
    await _select(t, short.id);
    expect(_sec(t), '1.2');
    // 1.5 秒以上變不了：按了長度不動、跳提示
    await _preset(t, '2');
    expect(short.length, closeTo(1.2, 1e-6));
    expect(find.text('這段最長 1.2 秒'), findsOneWidget);
    await _preset(t, '1');
    expect(short.length, closeTo(1, 1e-6));
    expect(_lane()[0].length, closeTo(2, 1e-6), reason: '別段不動');
    _expectContiguous();
    expect(_sec(t), '1');
    expect(_label(t).data, '這段');
    await _select(t, -1);
    expect(_sec(t), '2', reason: '每段照舊 2 秒');
    await drain(t);
  });

  testWidgets('快選來回換：換到原片結尾的那段，改長再改回來還是原本那一截', (t) async {
    await open(t);
    final first = _lane()[0]; // 原片 10 秒，取 4~6
    await _select(t, first.id);
    // 換段：換到最後 2 秒（8~10）
    await t.tap(find.text('換段'));
    await settle(t, 10);
    t.widget<SlipPicker>(find.byType(SlipPicker)).onCommitRange!(8, 2);
    await settle(t, 6);
    await t.tap(find.text('完成'));
    await settle(t, 10);
    expect(first.trimStart, closeTo(8, 1e-6));
    expect(first.trimEnd, closeTo(10, 1e-6));

    await _select(t, -1);
    await _preset(t, '5'); // 中心 9 拉到 5 秒會夾到結尾：5~10
    expect(first.trimStart, closeTo(5, 1e-6));
    expect(first.trimEnd, closeTo(10, 1e-6));
    await _preset(t, '2');
    expect(first.trimStart, closeTo(8, 1e-6), reason: '回到原本那一截，不是從 5~10 的中心縮');
    expect(first.trimEnd, closeTo(10, 1e-6));
    _expectContiguous();
    await drain(t);
  });

  testWidgets('換段：拉框邊剪短一段，後面照樣接上來（不留黑洞）', (t) async {
    await open(t);
    final first = _lane()[0];
    await _select(t, first.id);
    await t.tap(find.text('換段'));
    await settle(t, 10);
    final picker = t.widget<SlipPicker>(find.byType(SlipPicker));
    picker.onCommitRange!(first.trimStart, 1.0);
    await settle(t, 6);
    await t.tap(find.text('完成'));
    await settle(t, 10);
    expect(first.length, closeTo(1.0, 1e-6));
    _expectContiguous();
    expect(_tagColors('1.0s'), [kSelect], reason: '剪短的那段算個別改過');
    expect(_sec(t), '1', reason: '選著它：控制列寫這段的長度');
    await drain(t);
  });

  testWidgets('一般剪輯專案沒有秒數控制列、也不標秒數', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(videoPaths: [for (final n in _videos.keys) _p(n)]),
      ),
    );
    await settle(t, 60);
    expect(find.byKey(const ValueKey('vlog-bar')), findsNothing);
    expect(find.textContaining(RegExp(r'^\d+\.\ds$')), findsNothing);
    expect(_lane()[0].length, closeTo(10, 1e-6), reason: '一般匯入照舊整支');
    await drain(t);
  });

  testWidgets('上一步：一次快選、一次拖滑桿各退一步，長度跟每段的秒數一起退', (t) async {
    await open(t);
    await _slide(t, 3);
    await _preset(t, '1');
    await _slide(t, 4);
    expect(_sec(t), '4');
    double len(int i) => _lane()[i].length;

    await t.tap(undoButton());
    await settle(t, 6);
    expect(_sec(t), '1');
    expect(
      [len(0), len(1), len(2)],
      [closeTo(1, 1e-6), closeTo(1, 1e-6), closeTo(1, 1e-6)],
    );

    await t.tap(undoButton());
    await settle(t, 6);
    expect(_sec(t), '3');
    expect(len(0), closeTo(3, 1e-6));
    expect(len(1), closeTo(1.2, 1e-6));

    await t.tap(undoButton());
    await settle(t, 6);
    expect(_sec(t), '2', reason: '退回進場的樣子');
    expect(len(0), closeTo(2, 1e-6));
    expect(len(1), closeTo(1.2, 1e-6));
    expect(len(2), closeTo(2, 1e-6));
    _expectContiguous();

    // 只是按一下滑桿沒拖、按現在那顆（每一段本來就是 2）：都不算一步
    //（算的話會清掉下一步）
    expect(redoEnabled(t), isTrue);
    final s = t.widget<Slider>(find.byKey(const ValueKey('vlog-bar-slider')));
    s.onChangeStart?.call(s.value);
    s.onChangeEnd?.call(s.value);
    await _preset(t, '2');
    await settle(t, 6);
    expect(redoEnabled(t), isTrue, reason: '沒改到東西不該多一步');
    await t.tap(redoButton());
    await settle(t, 6);
    expect(_sec(t), '3', reason: '下一步照樣回得去');
    await drain(t);
  });
}
