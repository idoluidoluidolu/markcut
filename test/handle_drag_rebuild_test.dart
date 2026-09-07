// 守門：拖修剪把手／拖浮水印範圍，每一格只重畫時間軸（與預覽層），
// 不整頁重建。
//
// 以前 _trimClip／_trimWatermark／onMoveWm 每一格整頁 setState：120Hz
// 裝置拖把手＝每秒 120 次全頁 build（時間軸 ~400 個 element 之外還有
// 控制列、預覽整疊）。修法跟預覽手勢的 _setLive 同一條路：手勢中撥
// 專用的 notifier，TimelineEditor 自己 setState；放手才整頁。
//
// 跟 video_editor_gesture_rebuild_test 一樣用 Element.rebuild 的除錯鉤子
// 數「手勢中哪些 widget 被重建」
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/widgets/timeline_editor.dart';

const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
    'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=';
late final String _png;

/// 兩張圖在第 0 軌：1 號 0~4、2 號 4~8（圖片素材不需要播放器）
Map<String, dynamic> _draft() => {
  'savedAt': '2026-09-01T00:00:00.000',
  'sources': [
    MediaSource(
      path: _png,
      name: 't.png',
      kind: ClipKind.image,
      w: 400,
      h: 400,
      duration: 3600,
    ).toJson(),
  ],
  'clips': [
    TimelineClip(id: 1, sourceIndex: 0, trimStart: 0, trimEnd: 4, offset: 0, track: 0).toJson(),
    TimelineClip(id: 2, sourceIndex: 0, trimStart: 0, trimEnd: 4, offset: 4, track: 0).toJson(),
  ],
  'speed': 1.0,
  'ratio': 0,
  'res': 0,
  'quality': 0,
  'wmStart': 0.0,
  'extraTracks': 0,
};

Future<void> _settle(WidgetTester t, [int n = 25]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

TimelineModel _model(WidgetTester t) =>
    t.widget<TimelineEditor>(find.byType(TimelineEditor)).timeline;

TimelineClip _clip(WidgetTester t, int id) =>
    _model(t).clips.firstWhere((c) => c.id == id);

/// 選取的片段兩端各有一顆把手（drag_indicator 圖示），拿右邊那顆
Finder _rightHandle(WidgetTester t, int clipId) {
  final block = find.byKey(ValueKey('clip$clipId'));
  final icons = find.descendant(
    of: block,
    matching: find.byIcon(Icons.drag_indicator),
  );
  expect(icons, findsNWidgets(2), reason: '選取的片段要有兩顆把手');
  final a = t.getCenter(icons.at(0));
  final b = t.getCenter(icons.at(1));
  return a.dx < b.dx ? icons.at(1) : icons.at(0);
}

void main() {
  late Directory tmpDir;
  Map<String, int> rebuilt = {};

  void startCounting() {
    rebuilt = {};
    debugOnRebuildDirtyWidget = (e, _) {
      final k = e.widget.runtimeType.toString();
      rebuilt[k] = (rebuilt[k] ?? 0) + 1;
    };
  }

  void stopCounting() => debugOnRebuildDirtyWidget = null;
  int of(String k) => rebuilt[k] ?? 0;

  setUpAll(() {
    tmpDir = Directory.systemTemp.createTempSync('markcut_handle_');
    final f = File('${tmpDir.path}${Platform.pathSeparator}t.png')
      ..writeAsBytesSync(base64Decode(_pngB64));
    _png = f.path;
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

  tearDownAll(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugOnRebuildDirtyWidget = null);

  testWidgets('拖修剪把手：每格只重建時間軸，放手才整頁', (t) async {
    await t.pumpWidget(MaterialApp(home: VideoEditorScreen(draft: _draft())));
    await _settle(t);
    final r1 = t.getRect(find.byKey(const ValueKey('clip1')));
    await t.tapAt(r1.center);
    await _settle(t, 6);
    final len0 = _clip(t, 1).length;

    final g = await t.startGesture(t.getCenter(_rightHandle(t, 1)));
    await t.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(4, 0));
    await t.pump(const Duration(milliseconds: 16));
    const moves = 20;
    startCounting();
    for (var i = 0; i < moves; i++) {
      await g.moveBy(const Offset(3, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    stopCounting();
    expect(_clip(t, 1).length, greaterThan(len0), reason: '把手要真的在修剪');
    expect(
      of('TimelineEditor'),
      greaterThanOrEqualTo(moves ~/ 2),
      reason: '時間軸要在拖曳中持續重畫（片段寬度跟手）',
    );
    expect(
      of('VideoEditorScreen'),
      0,
      reason: '拖把手中不能整頁重建（以前每一格 setState）',
    );
    expect(of('AppBar'), 0, reason: '拖把手中不能整頁重建');

    startCounting();
    await g.up();
    await t.pump();
    stopCounting();
    expect(
      of('VideoEditorScreen'),
      greaterThanOrEqualTo(1),
      reason: '放手要整頁 setState 一次，值才落到時間碼／工具列',
    );
    await _settle(t, 40);
  });

  testWidgets('修剪浮水印範圍／拖範圍：每格不整頁重建，放手才整頁', (t) async {
    await t.pumpWidget(MaterialApp(home: VideoEditorScreen(draft: _draft())));
    await _settle(t);
    // 時間軸把 onTrimWm／onMoveWm 每一格叫一次；這裡直接叫回呼，量的是
    // 回呼本身做了什麼。手勢中頁面沒重建，同一個 widget 實例上的
    // watermark 值是舊的——範圍有沒有真的變，要等放手整頁重建後從新的
    // widget 讀
    TimelineEditor tlWidget() =>
        t.widget<TimelineEditor>(find.byType(TimelineEditor));
    final wm0 = tlWidget().watermark!;
    expect(wm0.end, closeTo(8, 1e-6), reason: '浮水印預設跟到結尾');

    // 右把手往左修 20 步（一步 0.05 秒）
    const moves = 20;
    final w1 = tlWidget();
    w1.onTrimWmStart!();
    startCounting();
    for (var i = 0; i < moves; i++) {
      w1.onTrimWm(-0.05, false);
      await t.pump(const Duration(milliseconds: 16));
    }
    stopCounting();
    expect(of('VideoEditorScreen'), 0, reason: '修剪浮水印中不能整頁重建');
    expect(
      of('TimelineEditor'),
      greaterThanOrEqualTo(moves ~/ 2),
      reason: '時間軸自己要跟著重畫（範圍長度跟手）',
    );
    startCounting();
    w1.onWmGestureEnd!();
    await t.pump();
    stopCounting();
    expect(of('VideoEditorScreen'), greaterThanOrEqualTo(1), reason: '放手補整頁');
    expect(
      tlWidget().watermark!.end,
      closeTo(7, 0.2),
      reason: '放手後頁面拿到的是修剪過的範圍',
    );

    // 整段範圍往右拖 20 步
    final w2 = tlWidget();
    startCounting();
    for (var i = 1; i <= moves; i++) {
      w2.onMoveWm(i * 0.02);
      await t.pump(const Duration(milliseconds: 16));
    }
    stopCounting();
    expect(of('VideoEditorScreen'), 0, reason: '拖範圍中不能整頁重建');
    expect(of('TimelineEditor'), greaterThanOrEqualTo(moves ~/ 2));
    startCounting();
    w2.onWmGestureEnd!();
    await t.pump();
    stopCounting();
    expect(of('VideoEditorScreen'), greaterThanOrEqualTo(1), reason: '放手補整頁');
    expect(tlWidget().watermark!.start, closeTo(0.4, 0.05), reason: '範圍真的搬了');
    // 起手拍快照排的存草稿（900ms）＋停手重組（350ms）要跑完，不能留
    // 著計時器離場
    await _settle(t, 40);
  });
}
