// 快速 Vlog：走真的編輯頁（首頁「快速 Vlog」挑好的那一批 → videoPaths＋
// vlogEntry，跟使用者的路一樣），中繼資料探測由假通道回。
//
// 使用者 11-07：「丟一堆影片進去、各取兩秒（預設）、可以調整時間跟段落、
// 串成一部；也可以個別調整影片長度，不卡死全部都要共同秒數」；畫布選甲
// ＝原本的剪輯畫面，左上多一顆「每段 N 秒」，選著一段時變「這段」。
//
// 守的是：
// - 進場每支取中間 2 秒、不到 2 秒整支、照挑選順序頭尾接；左上「每段 2 秒」；
//   不帶預設浮水印字；緊接開著
// - 改每段：跟著走的變、整軌接齊；時間軸片段右下角標秒數
// - 選一段：膠囊變「這段」、只改那段（琥珀秒數）；之後改每段不動它；
//   有自訂的才出現「全部統一」，按了一起改
// - 上一步：片段長度跟膠囊的秒數一起退回去
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

Future<void> _openPill(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('vlog-pill')));
  await settle(t, 6);
  expect(find.byKey(const ValueKey('vlog-sheet-slider')), findsOneWidget);
}

/// 照手指拖滑桿的順序叫：按下、拖到 [to]、放開
Future<void> _slide(WidgetTester t, double to) async {
  final s = t.widget<Slider>(find.byKey(const ValueKey('vlog-sheet-slider')));
  s.onChangeStart!(s.value);
  s.onChanged!(to);
  s.onChangeEnd!(to);
  await settle(t, 6);
}

Future<void> _closeSheet(WidgetTester t) async {
  await t.tapAt(const Offset(550, 40));
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

  testWidgets('進場：每支取中間 2 秒、不到 2 秒整支、照順序接；左上每段 2 秒', (t) async {
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

    expect(find.text('每段 2 秒'), findsOneWidget, reason: '左上要有每段膠囊');
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

  testWidgets('改每段：跟著走的變長、短的維持整支，整軌接齊', (t) async {
    await open(t);
    await _openPill(t);
    expect(
      find.byKey(const ValueKey('vlog-unify')),
      findsNothing,
      reason: '沒有自訂的段時不出現全部統一',
    );
    await _slide(t, 3);
    expect(find.text('3'), findsOneWidget, reason: '大數字跟著變');
    await _closeSheet(t);
    final lane = _lane();
    expect(lane[0].length, closeTo(3, 1e-6));
    expect(lane[0].trimStart, closeTo(3.5, 1e-6), reason: '中心不動');
    expect(lane[1].length, closeTo(1.2, 1e-6), reason: '原片只有 1.2 秒');
    expect(lane[2].length, closeTo(3, 1e-6));
    _expectContiguous();
    expect(find.text('每段 3 秒'), findsOneWidget);
    expect(_tagColors('3.0s'), [kText, kText]);
    await drain(t);
  });

  testWidgets('選一段＝只改這段；之後改每段不動它；全部統一一起改', (t) async {
    await open(t);
    final first = _lane()[0];
    editorOf(t).onSelect(first.id);
    await settle(t, 6);
    expect(find.text('這段 2 秒'), findsOneWidget, reason: '選著一段時膠囊變「這段」');
    await _openPill(t);
    await _slide(t, 4.5);
    await _closeSheet(t);
    var lane = _lane();
    expect(lane[0].length, closeTo(4.5, 1e-6));
    expect(lane[2].length, closeTo(2, 1e-6), reason: '別段不動');
    _expectContiguous();
    expect(find.text('這段 4.5 秒'), findsOneWidget);
    expect(_tagColors('4.5s'), [kSelect], reason: '個別改過的段標琥珀字');

    // 取消選取：回到每段；改每段時自訂的那段不動
    editorOf(t).onSelect(-1);
    await settle(t, 6);
    expect(find.text('每段 2 秒'), findsOneWidget);
    await _openPill(t);
    expect(
      find.byKey(const ValueKey('vlog-unify')),
      findsOneWidget,
      reason: '有自訂的段才出現全部統一',
    );
    await _slide(t, 1.5);
    lane = _lane();
    expect(lane[0].length, closeTo(4.5, 1e-6), reason: '自訂的不跟著每段走');
    expect(lane[1].length, closeTo(1.2, 1e-6));
    expect(lane[2].length, closeTo(1.5, 1e-6));
    _expectContiguous();

    await t.tap(find.byKey(const ValueKey('vlog-unify')));
    await settle(t, 6);
    lane = _lane();
    expect(lane[0].length, closeTo(1.5, 1e-6), reason: '全部統一');
    expect(lane[1].length, closeTo(1.2, 1e-6), reason: '原片只有 1.2 秒');
    expect(lane[2].length, closeTo(1.5, 1e-6));
    _expectContiguous();
    expect(
      find.byKey(const ValueKey('vlog-unify')),
      findsNothing,
      reason: '統一之後就沒有自訂的段了',
    );
    await _closeSheet(t);
    expect(find.text('每段 1.5 秒'), findsOneWidget);
    await drain(t);
  });

  testWidgets('換段：拉框邊剪短一段，後面照樣接上來（不留黑洞）', (t) async {
    await open(t);
    final first = _lane()[0];
    editorOf(t).onSelect(first.id);
    await settle(t, 6);
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
    await drain(t);
  });

  testWidgets('一般剪輯專案沒有每段膠囊、也不標秒數', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(videoPaths: [for (final n in _videos.keys) _p(n)]),
      ),
    );
    await settle(t, 60);
    expect(find.byKey(const ValueKey('vlog-pill')), findsNothing);
    expect(find.textContaining(RegExp(r'^\d+\.\ds$')), findsNothing);
    expect(_lane()[0].length, closeTo(10, 1e-6), reason: '一般匯入照舊整支');
    await drain(t);
  });

  testWidgets('上一步：片段長度跟每段的秒數一起退回去', (t) async {
    await open(t);
    await _openPill(t);
    await _slide(t, 3);
    await _slide(t, 4);
    await _closeSheet(t);
    expect(find.text('每段 4 秒'), findsOneWidget);
    expect(undoEnabled(t), isTrue);
    await t.tap(undoButton());
    await settle(t, 6);
    expect(find.text('每段 2 秒'), findsOneWidget, reason: '整張表算一步，退回打開之前');
    for (final c in _lane()) {
      expect(c.length, closeTo(c == _lane()[1] ? 1.2 : 2, 1e-6));
    }
    _expectContiguous();
    await drain(t);
  });
}
