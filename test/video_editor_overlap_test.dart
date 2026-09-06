// 真實的影片編輯頁上重現使用者的操作：同軌片段拉長時，後面的被推開，
// 不是被蓋住；舊草稿裡的重疊在載入時就被推開。
//
// 用圖片素材（不需要影片播放器）跑整頁：圖片跟影片一樣受「同軌不重疊」
// 管（exclusiveOnTrack），走的是同一條 _trimClip／_loadDraft。
// 素材圖是測試自己寫出來的 8×8 PNG
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

/// 兩張圖在第 0 軌：1 號 0~4、2 號 3~7——這一版之前存下來的草稿就可能
/// 長這樣（右把手拉過去沒人擋）
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
    TimelineClip(id: 2, sourceIndex: 0, trimStart: 0, trimEnd: 4, offset: 3, track: 0).toJson(),
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

/// 選取的片段兩端各有一顆把手（drag_indicator 圖示），拿左邊或右邊那顆
Finder _handle(WidgetTester t, int clipId, {required bool left}) {
  final block = find.byKey(ValueKey('clip$clipId'));
  final icons = find.descendant(
    of: block,
    matching: find.byIcon(Icons.drag_indicator),
  );
  expect(icons, findsNWidgets(2), reason: '選取的片段要有兩顆把手');
  final a = t.getCenter(icons.at(0));
  final b = t.getCenter(icons.at(1));
  final wantLeft = a.dx < b.dx ? icons.at(0) : icons.at(1);
  final wantRight = a.dx < b.dx ? icons.at(1) : icons.at(0);
  return left ? wantLeft : wantRight;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  late Directory tmpDir;
  tearDownAll(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });
  setUpAll(() {
    tmpDir = Directory.systemTemp.createTempSync('markcut_overlap_');
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

  testWidgets('舊草稿的同軌重疊：載入時就推開；右把手拉長把後面的推走、左把手頂到前一段就停', (t) async {
    await t.pumpWidget(MaterialApp(home: VideoEditorScreen(draft: _draft())));
    await _settle(t);

    // ── 載入正規化：2 號從 3 被推到 1 號的結尾 4，兩段都還在 ──
    final tl = _model(t);
    expect(tl.clips.length, 2);
    expect(_clip(t, 1).end, closeTo(4, 1e-9));
    expect(_clip(t, 2).offset, closeTo(4, 1e-9), reason: '載入時同軌重疊要推開');
    expect(_clip(t, 2).length, closeTo(4, 1e-9), reason: '推開不裁');
    expect(tl.firstOverlapOnTracks(), isNull);
    // 畫面上也是頭尾相接
    final r1 = t.getRect(find.byKey(const ValueKey('clip1')));
    final r2 = t.getRect(find.byKey(const ValueKey('clip2')));
    expect(r2.left, closeTo(r1.right, 1.5), reason: '時間軸上 2 號的頭貼著 1 號的尾');
    final pxPerSec = r1.width / _clip(t, 1).length;

    // ── 選 1 號，把右把手往右拖 90px（1.5 秒）：2 號被推 1.5 秒，不被蓋 ──
    await t.tapAt(r1.center);
    await _settle(t, 6);
    await t.drag(_handle(t, 1, left: false), const Offset(90, 0));
    await _settle(t, 6);
    final grown = _clip(t, 1).length - 4;
    expect(grown, closeTo(90 / pxPerSec, 0.02), reason: '1 號拉長了把手走的量');
    expect(
      _clip(t, 2).offset,
      closeTo(_clip(t, 1).end, 1e-9),
      reason: '2 號被推到 1 號的新結尾，不是被蓋住',
    );
    expect(_clip(t, 2).length, closeTo(4, 1e-9), reason: '2 號一格都沒被裁');
    expect(tl.firstOverlapOnTracks(), isNull);
    final r1b = t.getRect(find.byKey(const ValueKey('clip1')));
    final r2b = t.getRect(find.byKey(const ValueKey('clip2')));
    expect(r2b.left, closeTo(r1b.right, 1.5), reason: '畫面上還是頭尾相接');

    // ── 選 2 號，把左把手往左拖 60px：地板是 1 號的結尾，頂到就停 ──
    await t.tapAt(r2b.center);
    await _settle(t, 6);
    final end2 = _clip(t, 2).end;
    await t.drag(_handle(t, 2, left: true), const Offset(-60, 0));
    await _settle(t, 6);
    expect(
      _clip(t, 2).offset,
      closeTo(_clip(t, 1).end, 1e-9),
      reason: '左把手往前長不能壓進前一段',
    );
    expect(_clip(t, 2).end, closeTo(end2, 1e-9), reason: '圖片的右緣不動');
    expect(tl.firstOverlapOnTracks(), isNull);

    // 讓併批的草稿存檔跑完，別留計時器
    await _settle(t, 30);
  });
}
