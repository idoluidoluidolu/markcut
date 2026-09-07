// 真實的影片編輯頁上重現使用者的操作：右把手拉長時後面的被推開，不是
// 被蓋住；左把手往前長進前一段時前一段讓位（尾巴縮到新起點），不是頂住
// 不動、也不是自己往右長；舊草稿裡的重疊在載入時就被推開。
//
// 第一支用圖片素材（不需要影片播放器）跑整頁：圖片跟影片一樣受「同軌
// 不重疊」管（exclusiveOnTrack），走的是同一條 _trimClip／_loadDraft。
// 素材圖是測試自己寫出來的 8×8 PNG。第二支用影片（合成通道 mock 掉，
// 跟 video_editor_gesture_rebuild_test 一樣）：左把手往前露出的頭到素材
// 開頭就停，這條上限只有影片才有
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
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

  testWidgets('舊草稿的同軌重疊：載入時就推開；右把手拉長把後面的推走、左把手往前長讓前一段縮短', (t) async {
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

    // ── 選 2 號，把左把手往左拖 60px（1 秒）：1 號的尾巴讓到 2 號的新起點 ──
    // 實機測試回報「在後方的影片往前延伸，應該是前面那部要往前縮起來讓位
    // 給他」。這裡以前釘的是「地板是 1 號的結尾，頂到就停」
    await t.tapAt(r2b.center);
    await _settle(t, 6);
    final before1 = jsonEncode(_clip(t, 1).toJson());
    final before2 = jsonEncode(_clip(t, 2).toJson());
    final end1 = _clip(t, 1).end;
    final end2 = _clip(t, 2).end;
    await t.drag(_handle(t, 2, left: true), const Offset(-60, 0));
    await _settle(t, 6);
    expect(
      end1 - _clip(t, 2).offset,
      closeTo(60 / pxPerSec, 0.02),
      reason: '2 號的起點往前了把手走的量，沒有被 1 號的尾巴擋住',
    );
    expect(
      _clip(t, 1).end,
      closeTo(_clip(t, 2).offset, 1e-9),
      reason: '1 號的尾巴縮到 2 號的新起點（讓位）',
    );
    expect(_clip(t, 1).offset, 0.0, reason: '1 號的起點不動：是縮，不是被推');
    expect(_clip(t, 2).end, closeTo(end2, 1e-9), reason: '2 號的右緣不動：不是往右長');
    expect(tl.firstOverlapOnTracks(), isNull);
    final r1c = t.getRect(find.byKey(const ValueKey('clip1')));
    final r2c = t.getRect(find.byKey(const ValueKey('clip2')));
    expect(r2c.left, closeTo(r1c.right, 1.5), reason: '畫面上還是頭尾相接');

    // ── 復原：一步退回，兩段一起回到讓位前 ──
    await t.tap(find.byIcon(Icons.undo));
    await _settle(t, 6);
    expect(jsonEncode(_clip(t, 1).toJson()), before1, reason: '復原：1 號的尾巴回來');
    expect(jsonEncode(_clip(t, 2).toJson()), before2, reason: '復原：2 號的起點回來');

    // ── 再選 2 號，左把手一路往左拖 600px：1 號讓到最短（目前縮放下的
    // 煞車寬）就擋住——2 號的起點釘在那裡、右緣還是不動，不會改往右長 ──
    await t.tapAt(r2b.center);
    await _settle(t, 6);
    await t.drag(_handle(t, 2, left: true), const Offset(-600, 0));
    await _settle(t, 6);
    final minLen = math.max(kMinClipLen, kTrimStopWidth / pxPerSec);
    expect(_clip(t, 1).length, closeTo(minLen, 0.02), reason: '1 號讓到最短就不再縮');
    expect(_clip(t, 1).offset, 0.0);
    expect(
      _clip(t, 2).offset,
      closeTo(_clip(t, 1).end, 1e-9),
      reason: '2 號的起點釘在 1 號讓完的尾巴',
    );
    expect(_clip(t, 2).end, closeTo(end2, 1e-9), reason: '擋住之後右緣也不動：不是往右長');
    expect(tl.firstOverlapOnTracks(), isNull);

    // 讓併批的草稿存檔與提示跑完，別留計時器
    await _settle(t, 80);
  });

  testWidgets('影片：左把手往前露出的頭到素材開頭就停，1 號只讓到那裡', (t) async {
    // 影片走合成播放器：把原生合成通道 mock 掉（available／build），
    // 頁面才肯把影片當影片（跟 video_editor_gesture_rebuild_test 一樣）
    const compCh = MethodChannel('markcut/comp');
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          return <String, dynamic>{
            'textureId': 1,
            'duration': 8.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
      }
      return null;
    });
    addTearDown(() => b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null));
    // 系統影片圖層是原生 platform view，測試環境沒有；走 Flutter 材質
    final layerWas = Diag.playerLayer.value;
    Diag.playerLayer.value = false;
    addTearDown(() => Diag.playerLayer.value = layerWas);

    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
    await _settle(t, 5);
    // 1 號 0~4（素材 0~4）、2 號 4~8（素材 1~5：往前只剩 1 秒可以露）
    VideoEditorScreen.debugTimeline!((m) {
      m.sources.add(
        MediaSource(
          path: '/v.mp4',
          name: 'v',
          kind: ClipKind.video,
          duration: 100,
          workPath: '/v.work.mp4',
        ),
      );
      m.clips.add(
        TimelineClip(id: 1, sourceIndex: 0, trimStart: 0, trimEnd: 4, offset: 0, track: 0),
      );
      m.clips.add(
        TimelineClip(id: 2, sourceIndex: 0, trimStart: 1, trimEnd: 5, offset: 4, track: 0),
      );
      m.ensureIdAbove(2);
    });
    await _settle(t, 15);
    final tl = _model(t);
    final r1 = t.getRect(find.byKey(const ValueKey('clip1')));
    final r2 = t.getRect(find.byKey(const ValueKey('clip2')));
    final pxPerSec = r1.width / 4;

    // ── 選 2 號，左把手往左拖 3 秒的量：素材開頭 1 秒露完就停 ──
    await t.tapAt(r2.center);
    await _settle(t, 6);
    await t.drag(_handle(t, 2, left: true), Offset(-3 * pxPerSec, 0));
    await _settle(t, 6);
    expect(_clip(t, 2).trimStart, closeTo(0, 1e-6), reason: '露到素材開頭');
    expect(_clip(t, 2).offset, closeTo(3, 1e-6), reason: '起點只往前了露得出來的 1 秒');
    expect(_clip(t, 2).end, closeTo(8, 1e-6), reason: '右緣不動：不是往右長');
    expect(
      _clip(t, 1).end,
      closeTo(_clip(t, 2).offset, 1e-9),
      reason: '1 號的尾巴讓到 2 號的新起點，只讓那 1 秒',
    );
    expect(_clip(t, 1).trimEnd, closeTo(3, 1e-6), reason: '修的是 1 號的素材出點');
    expect(_clip(t, 1).offset, 0.0);
    expect(tl.firstOverlapOnTracks(), isNull);
    final r1b = t.getRect(find.byKey(const ValueKey('clip1')));
    final r2b = t.getRect(find.byKey(const ValueKey('clip2')));
    expect(r2b.left, closeTo(r1b.right, 1.5), reason: '畫面上頭尾相接');

    // 復原不在這支驗：_restoreSnapshot 會替每個影片片段重開播放器
    //（_ensureCtrlFor），測試主機沒有 libmpv，整頁會炸掉。復原兩段一起
    // 回來由上面那支（圖片）跟 trim_into_prev_test 的快照測試守著

    // 讓併批的草稿存檔跑完，別留計時器
    await _settle(t, 80);
  });
}
