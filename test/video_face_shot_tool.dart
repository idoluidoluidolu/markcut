// 影片自動碼人臉的截圖工具（不是回歸測試）。
//
// 真的佈景（工作室深色）、真的字體（NotoSansTC＋Material Icons）、iPhone 14
// 視窗（390×844、DPR 3、安全區 47/34）。走真的路：加素材 → 馬賽克 → 選單 →
// 自動碼人臉 → 每個人一條軌（標籤是頭像）→ 點掉一個人（虛線圈＋斜線頭像）：
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/video_face_shot_tool.dart
//
// 找臉通道回三個人的位置，抽幀通道回自己畫的那一格（頭像從它裁）。
// 預覽是合成播放器的貼圖，測試裡畫不出影片內容（黑的）；碼上去的效果要看
// 實機，這裡看的是時間軸、標籤、虛線圈、選單。
// 沒設環境變數時整支略過。檔名沒有 _test 結尾，整批 flutter test 也不會撿它。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/theme.dart';

import 'editor_harness.dart';

final _shotKey = GlobalKey();

String? _materialIconsPath() {
  final candidates = <String>[];
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    candidates.add(
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  final exe = Platform.resolvedExecutable.replaceAll(
    String.fromCharCode(92),
    '/',
  );
  final i = exe.indexOf('/bin/cache/');
  if (i >= 0) {
    candidates.add(
      '${exe.substring(0, i)}'
      '/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

/// 三個人（1920×1080 那一格的像素）
const _heads = [
  (
    x: 520.0,
    y: 470.0,
    r: 120.0,
    skin: 0xFFE0B08A,
    hair: 0xFF2E2420,
    shirt: 0xFFE66F51,
  ),
  (
    x: 960.0,
    y: 430.0,
    r: 130.0,
    skin: 0xFFC98F67,
    hair: 0xFF4A3426,
    shirt: 0xFF3E6FA8,
  ),
  (
    x: 1400.0,
    y: 480.0,
    r: 115.0,
    skin: 0xFFEDC39E,
    hair: 0xFF1F1A17,
    shirt: 0xFF4E9A7A,
  ),
];
const _w = 1920.0, _h = 1080.0;

Future<Uint8List> _scene() async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, _w, _h * 0.6),
    Paint()..color = const Color(0xFFA9C9DA),
  );
  c.drawRect(
    const Rect.fromLTWH(0, _h * 0.6, _w, _h * 0.4),
    Paint()..color = const Color(0xFFD2C29F),
  );
  for (final p in _heads) {
    final r = p.r;
    c.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(p.x - 1.7 * r, p.y + 0.85 * r, 3.4 * r, _h),
        topLeft: Radius.circular(r * 1.1),
        topRight: Radius.circular(r * 1.1),
      ),
      Paint()..color = Color(p.shirt),
    );
    c.drawCircle(Offset(p.x, p.y), r, Paint()..color = Color(p.skin));
    c.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(p.x - 1.05 * r, p.y - 1.1 * r, 2.1 * r, 1.05 * r),
        topLeft: Radius.circular(r * 1.05),
        topRight: Radius.circular(r * 1.05),
        bottomLeft: Radius.circular(r * 0.25),
        bottomRight: Radius.circular(r * 0.25),
      ),
      Paint()..color = Color(p.hair),
    );
    for (final dx in const [-0.36, 0.36]) {
      c.drawCircle(
        Offset(p.x + dx * r, p.y + 0.12 * r),
        r * 0.08,
        Paint()..color = const Color(0xFF2A211C),
      );
    }
  }
  final img = await rec.endRecording().toImage(_w.toInt(), _h.toInt());
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '截圖工具，要給輸出資料夾才會跑');
    return;
  }

  late Uint8List frame;
  late FakeComp comp;

  setUpAll(() async {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    mockEditorPlugins(b);
    Directory(out).createSync(recursive: true);
    for (final path in const [
      'assets/fonts/NotoSansTC.ttf',
      'assets/fonts/NotoSansTC-Bold.ttf',
    ]) {
      final loader = FontLoader('NotoSansTC')
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
    final icons = _materialIconsPath();
    expect(icons, isNotNull, reason: '找不到 materialicons-regular.otf');
    final il = FontLoader('MaterialIcons')
      ..addFont(File(icons!).readAsBytes().then((b) => b.buffer.asByteData()));
    await il.load();
    frame = await _scene();
    File('$out${Platform.pathSeparator}vf_scene.png').writeAsBytesSync(frame);
    // 找臉：0~4 秒每 0.1 秒一格，三個人慢慢往右走一點
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/face'),
      (call) async {
        if (call.method != 'analyzeVideo') return null;
        return [
          for (var i = 0; i <= 40; i++)
            {
              't': i / 10,
              'f': [
                for (final p in _heads)
                  [
                    (p.x + i * 2 - 0.8 * p.r) / _w,
                    (p.y - 0.6 * p.r) / _h,
                    1.6 * p.r / _w,
                    1.5 * p.r / _h,
                  ],
              ],
            },
        ];
      },
    );
    // 抽幀：頭像從這一格裁
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/frames'),
      (call) async => call.method == 'frameAt' ? frame : null,
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
    comp = FakeComp(TestWidgetsFlutterBinding.ensureInitialized())
      ..duration = 6.0
      ..install();
  });
  tearDown(() => comp.uninstall());

  void phone(WidgetTester t) {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);
  }

  Future<void> snap(WidgetTester t, String name) async {
    await t.runAsync(() async {
      final b =
          _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await b.toImage(pixelRatio: 3);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      im.dispose();
      File(
        '$out${Platform.pathSeparator}$name',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('加素材 → 馬賽克 → 自動碼人臉 → 點掉一個人', (t) async {
    phone(t);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: const VideoEditorScreen(blank: true),
        ),
      ),
    );
    await settle(t, 8);
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
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 6,
          offset: 0,
          track: 0,
        ),
      );
    });
    await settle(t, 15);

    editorOf(t).onAddMedia(1);
    await settle(t, 10);
    await t.tap(find.text('馬賽克').last);
    await settle(t, 10);
    await snap(t, 'vf_1_sheet.png');

    await t.tap(find.text('自動碼人臉'));
    await settle(t, 30);
    editorOf(t).onSeek(1.5);
    await settle(t, 10);
    await snap(t, 'vf_2_tracks.png');

    final faces = [
      for (final c in modelOf(t).clips)
        if (modelOf(t).sourceOf(c).mosaicFace) c,
    ]..sort((a, b) => a.track.compareTo(b.track));
    editorOf(t).onToggleHidden!(faces[1].track);
    await settle(t, 10);
    await snap(t, 'vf_3_off.png');
    editorOf(t).onToggleHidden!(faces[1].track);
    await settle(t, 10);

    // 10-25：三種馬賽克各開各的樣式表、標題寫明
    Future<void> closeSheet() async {
      await t.tapAt(const Offset(20, 120));
      await settle(t, 10);
    }

    editorOf(t).onTapSelectedClip!(faces[0].id);
    await settle(t, 10);
    await snap(t, 'vf_4_face_sheet.png');
    await t.tap(find.text('模糊'));
    await settle(t, 10);
    await snap(t, 'vf_4b_face_blur.png');
    await closeSheet();

    editorOf(t).onAddMedia(1);
    await settle(t, 10);
    await t.tap(find.text('馬賽克').last);
    await settle(t, 10);
    await t.tap(find.text('方框'));
    await settle(t, 15);
    final box = modelOf(
      t,
    ).clips.lastWhere((c) => modelOf(t).sourceOf(c).kind == ClipKind.mosaic);
    editorOf(t).onTapSelectedClip!(box.id);
    await settle(t, 10);
    await snap(t, 'vf_5_box_sheet.png');
    await closeSheet();

    late TimelineClip stroke;
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(
          path: '',
          name: '筆刷馬賽克',
          kind: ClipKind.mosaic,
          duration: 3600,
          mosaicStyle: MosaicStyle(),
          mosaicStroke: [0.2, 0.6, 0.5, 0.7, 0.7, 0.6],
          mosaicBrush: 0.08,
        ),
      );
      stroke = TimelineClip(
        id: tl.nextId(),
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: 3,
        offset: 0,
        track: tl.usedTracks,
      );
      tl.clips.add(stroke);
    });
    await settle(t, 10);
    editorOf(t).onTapSelectedClip!(stroke.id);
    await settle(t, 10);
    await snap(t, 'vf_6_brush_sheet.png');
    await closeSheet();
    await settle(t, 80);
  });
}
