// 影片去背：走真的編輯頁，選片段 → 工具列「去背」→ 打開。原生的去背
// 通道（markcut/cutout）換成假的（照格式寫一個小遮罩檔），合成播放器
// 也是假的（看送過去的欄位）。
//
// 守的是：
//   1. 打開＝片段記著去背、背景透明；遮罩照原檔算（解的是工作檔），
//      算好登記在工作檔索引、素材記著遮罩檔
//   2. 遮罩好了合成馬上重組，payload 帶 cutout（遮罩檔、開頭的遮罩秒數、
//      方向、背景）；換純色背景、關掉都跟著重組
//   3. 同一支原檔已經算過：不再算一次
//   4. 原生算不成：提示、去背表給「重試」，按了重算
//   5. 上一步退得回來
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/cutout_mask.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/work_files.dart';

import 'editor_harness.dart';

const _cutout = MethodChannel('markcut/cutout');

void main() {
  late FakeComp comp;
  late Directory dir;
  final masked = <String>[];
  var fail = false;

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
    masked.clear();
    fail = false;
    dir = Directory.systemTemp.createTempSync('markcut_vcut_');
    WorkFiles.resetForTest();
    WorkFiles.supportDirOverride = dir;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    comp = FakeComp(b)
      ..duration = 5.0
      ..install();
    b.defaultBinaryMessenger.setMockMethodCallHandler(_cutout, (call) async {
      if (call.method != 'videoMask') return null;
      final a = call.arguments as Map;
      masked.add(a['path'] as String);
      if (fail) {
        throw PlatformException(code: 'cutout_failed', message: '算遮罩｜測試失敗');
      }
      final w = CutoutMaskWriter(a['out'] as String, 4, 4);
      for (var i = 0; i < 3; i++) {
        w.add(i * 1.0, Uint8List(16)..fillRange(0, 8, 255));
      }
      w.close();
      return {'frames': 3, 'w': 4, 'h': 4};
    });
  });

  tearDown(() {
    comp.uninstall();
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(_cutout, null);
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  late int clipId;

  Future<void> openWithVideo(WidgetTester t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(
          path: '/v.mp4',
          name: 'v',
          kind: ClipKind.video,
          duration: 10,
          w: 1920,
          h: 1080,
          workPath: '/v.work.mp4',
        ),
      );
      clipId = tl.nextId();
      tl.clips.add(
        TimelineClip(
          id: clipId,
          sourceIndex: 0,
          trimStart: 1,
          trimEnd: 5,
          offset: 0,
          track: 0,
        ),
      );
    });
    await tick(t, 15);
  }

  Future<void> openSheet(WidgetTester t) async {
    await t.tap(clipBlock(clipId));
    await tick(t, 5);
    final btn = find.text('去背');
    await t.ensureVisible(btn);
    await tick(t, 3);
    await t.tap(btn);
    await tick(t, 15);
    expect(find.text('人像去背'), findsOneWidget);
  }

  /// 最近一次組合成送的第一段影片
  Map<Object?, Object?> lastClip() =>
      ((comp.buildArgs.last['clips'] as List).first as Map)
          .cast<Object?, Object?>();

  testWidgets('打開去背：照原檔算遮罩、登記索引；合成收到遮罩欄位，換背景、關掉跟著重組', (t) async {
    await openWithVideo(t);
    await openSheet(t);
    await t.tap(find.byType(Switch));
    await settle(t, 10);
    await tick(t, 15);

    final c = modelOf(t).clips.single;
    final s = modelOf(t).sourceOf(c);
    expect(c.cutout, ClipCutout(), reason: '打開＝背景透明');
    expect(masked, ['/v.work.mp4'], reason: '照原檔算：工作檔轉好了就解工作檔');
    expect(s.cutMask, isNotNull);
    expect(s.cutMask, endsWith('.mcmk'));
    expect(
      await WorkFiles.lookupCutout('/v.mp4'),
      s.cutMask,
      reason: '登記在原檔名下',
    );

    var cut = (lastClip()['cutout'] as Map).cast<Object?, Object?>();
    expect(cut['mask'], s.cutMask);
    expect(cut['m0'], 1.0, reason: '片段從素材 1 秒開始');
    expect(cut['dir'], 1);
    expect(cut['bg'], 0);

    // 換純色：預設白
    await t.tap(find.text('純色'));
    await tick(t, 15);
    cut = (lastClip()['cutout'] as Map).cast<Object?, Object?>();
    expect(cut['bg'], 1);
    expect(cut['color'], 0xFFFFFFFF);
    expect(c.cutout!.bg, CutoutBg.color);

    // 關掉：不送 cutout
    await t.tap(find.byType(Switch));
    await tick(t, 15);
    expect(c.cutout, isNull);
    expect(lastClip().containsKey('cutout'), isFalse);
    expect(masked, hasLength(1), reason: '開關不會重算');
    await settle(t, 40);
  });

  testWidgets('同一支原檔已經算過：直接接上，不再算一次', (t) async {
    final pre = await WorkFiles.beginCutout();
    CutoutMaskWriter(pre, 4, 4)
      ..add(0, Uint8List(16))
      ..close();
    await WorkFiles.commitCutout('/v.mp4', pre);

    await openWithVideo(t);
    await openSheet(t);
    await t.tap(find.byType(Switch));
    await settle(t, 10);
    expect(masked, isEmpty, reason: '索引裡有就不用算');
    expect(modelOf(t).sources.single.cutMask, pre);
    await settle(t, 40);
  });

  testWidgets('原生算不成：提示、去背表給重試，按了重算；上一步關回去', (t) async {
    fail = true;
    await openWithVideo(t);
    await openSheet(t);
    await t.tap(find.byType(Switch));
    await settle(t, 10);
    await tick(t, 5);
    expect(modelOf(t).sources.single.cutMask, isNull);
    expect(find.text('去背沒算成'), findsOneWidget, reason: '去背表要講沒算成');
    expect(find.textContaining('算遮罩｜測試失敗'), findsOneWidget, reason: '提示帶原因');

    fail = false;
    await t.tap(find.text('重試'));
    await settle(t, 10);
    await tick(t, 5);
    expect(masked, hasLength(2));
    expect(modelOf(t).sources.single.cutMask, isNotNull);
    expect(find.text('去背沒算成'), findsNothing);

    // 收起去背表、上一步：去背關回去
    Navigator.of(t.element(find.text('人像去背'))).pop();
    await tick(t, 15);
    await t.tap(undoButton());
    await tick(t, 10);
    expect(modelOf(t).clips.single.cutout, isNull);
    await settle(t, 40);
  });
}
