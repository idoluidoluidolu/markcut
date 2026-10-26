// 去背截圖工具（不是回歸測試）。
//
// 用真的佈景、真的字體（NotoSansTC＋Material Icons）、iPhone 14 視窗
//（390×844、DPR 3、安全區 47/34），把首頁選單（第六列去背＋第二層）、
// 照片去背頁（找到兩個主體 → 點掉一個 → 修邊 → 換背景）、剪輯的去背表
// 拍成 PNG，給設計檢視用：
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/cutout_shot_tool.dart
//
// 照片是自己畫的（一個人、一顆球），去背通道照畫的形狀回遮罩。
// 沒設環境變數時整支略過。檔名沒有 _test 結尾，整批 flutter test 也不會撿它。
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/cutout_screen.dart';
import 'package:markcut/screens/home_screen.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/cutout_mask.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/cutout_swatch.dart';

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

/// 照片 1200×900：人站左邊（頭＋身體）、一顆球在右下
const _w = 1200.0, _h = 900.0;
const _head = (x: 420.0, y: 300.0, r: 110.0);
const _body = Rect.fromLTWH(250, 400, 340, 500);
const _ball = (x: 900.0, y: 640.0, r: 150.0);

/// 照片座標的一點屬於哪個主體：1＝人、2＝球、0＝背景
int _label(double x, double y) {
  if (math.pow(x - _head.x, 2) + math.pow(y - _head.y, 2) <=
          _head.r * _head.r ||
      _body.contains(Offset(x, y))) {
    return 1;
  }
  if (math.pow(x - _ball.x, 2) + math.pow(y - _ball.y, 2) <=
      _ball.r * _ball.r) {
    return 2;
  }
  return 0;
}

Future<Uint8List> _scene() async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, _w, _h * 0.6),
    Paint()..color = const Color(0xFF9DB7CF),
  );
  c.drawRect(
    const Rect.fromLTWH(0, _h * 0.6, _w, _h * 0.4),
    Paint()..color = const Color(0xFF8FA36B),
  );
  c.drawRRect(
    RRect.fromRectAndCorners(
      _body,
      topLeft: const Radius.circular(120),
      topRight: const Radius.circular(120),
    ),
    Paint()..color = const Color(0xFFD9694F),
  );
  c.drawCircle(
    const Offset(420, 300),
    110,
    Paint()..color = const Color(0xFFE6BC98),
  );
  c.drawArc(
    Rect.fromCircle(center: const Offset(420, 290), radius: 118),
    math.pi,
    math.pi,
    true,
    Paint()..color = const Color(0xFF2F2621),
  );
  c.drawCircle(
    const Offset(900, 640),
    150,
    Paint()..color = const Color(0xFFF2C14E),
  );
  c.drawArc(
    Rect.fromCircle(center: const Offset(900, 640), radius: 150),
    -0.6,
    1.2,
    false,
    Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14,
  );
  final img = await rec.endRecording().toImage(_w.toInt(), _h.toInt());
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

/// 分析尺寸 400×300 的遮罩／標籤
const _aw = 400, _ah = 300;

Uint8List _mask(Set<int> ids, {bool labels = false}) {
  final m = Uint8List(_aw * _ah);
  for (var y = 0; y < _ah; y++) {
    for (var x = 0; x < _aw; x++) {
      final l = _label((x + 0.5) * _w / _aw, (y + 0.5) * _h / _ah);
      m[y * _aw + x] = labels ? l : (ids.contains(l) ? 255 : 0);
    }
  }
  return m;
}

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '截圖工具，要給輸出資料夾才會跑');
    return;
  }

  late String photoPath;

  setUpAll(() async {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
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
    photoPath = '$out${Platform.pathSeparator}cut_scene.png';
    File(photoPath).writeAsBytesSync(await _scene());
    mockEditorPlugins(b);
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/cutout'),
      (call) async {
        switch (call.method) {
          case 'analyzePhoto':
            return {
              'w': _aw,
              'h': _ah,
              'fullW': _w.toInt(),
              'fullH': _h.toInt(),
              'kind': 'subject',
              'mask': _mask({1, 2}),
              'labels': _mask({}, labels: true),
              'lw': _aw,
              'lh': _ah,
              'subjects': [
                {'id': 1, 'x': 0.2, 'y': 0.2, 'w': 0.3, 'h': 0.8},
                {'id': 2, 'x': 0.625, 'y': 0.54, 'w': 0.25, 'h': 0.34},
              ],
            };
          case 'photoMask':
            final ids = ((call.arguments as Map)['ids'] as List).cast<int>();
            return {'w': _aw, 'h': _ah, 'mask': _mask(ids.toSet())};
          case 'videoMask':
            final a = call.arguments as Map;
            CutoutMaskWriter(a['out'] as String, 4, 4)
              ..add(0, Uint8List(16))
              ..close();
            return {'frames': 1, 'w': 4, 'h': 4};
        }
        return null;
      },
    );
  });

  void phone(WidgetTester t) {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);
  }

  Future<void> settle(WidgetTester t, [int n = 15]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
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

  testWidgets('首頁選單：第六列去背 → 第二層', (t) async {
    SharedPreferences.setMockInitialValues({kHomeProfileHintKey: true});
    phone(t);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: const LightPage(child: HomeScreen()),
        ),
      ),
    );
    await settle(t);
    await t.tap(find.byType(FloatingActionButton));
    await settle(t);
    await snap(t, 'cut_home_menu.png');
    await t.tap(find.text('去背'));
    await settle(t);
    await snap(t, 'cut_home_second.png');
  });

  testWidgets('照片去背：找到兩個 → 點掉球 → 修邊 → 背景', (t) async {
    SharedPreferences.setMockInitialValues({});
    phone(t);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: CutoutScreen(photo: XFile(photoPath, name: 'cut_scene.png')),
        ),
      ),
    );
    await settle(t, 25);
    await snap(t, 'cut_photo.png');

    final avatars = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_SubjectAvatar',
    );
    await t.tap(avatars.at(1));
    await settle(t, 10);
    await snap(t, 'cut_photo_one.png');

    await t.tap(find.text('修邊'));
    await settle(t, 3);
    await snap(t, 'cut_photo_brush.png');

    await t.tap(find.text('背景'));
    await settle(t, 3);
    await t.tap(find.text('模糊'));
    await settle(t, 6);
    await snap(t, 'cut_photo_blur.png');
    await t.tap(find.byType(CutoutSwatch).at(3));
    await settle(t, 6);
    await snap(t, 'cut_photo_green.png');
  });

  testWidgets('剪輯的去背表', (t) async {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
    phone(t);
    final dir = Directory.systemTemp.createTempSync('markcut_cutshot_');
    WorkFiles.resetForTest();
    WorkFiles.supportDirOverride = dir;
    final comp = FakeComp(TestWidgetsFlutterBinding.ensureInitialized())
      ..install();
    addTearDown(() {
      comp.uninstall();
      WorkFiles.supportDirOverride = null;
      WorkFiles.resetForTest();
    });
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
    await settle(t, 5);
    late int id;
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(
          path: '/v.mp4',
          name: 'v',
          kind: ClipKind.video,
          duration: 10,
          w: 1080,
          h: 1920,
          workPath: '/v.work.mp4',
        ),
      );
      id = tl.nextId();
      tl.clips.add(
        TimelineClip(
          id: id,
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 5,
          offset: 0,
          track: 0,
        ),
      );
    });
    await settle(t, 10);
    await t.tap(find.byKey(ValueKey('clip$id')));
    await settle(t, 3);
    await snap(t, 'cut_editor_toolbar.png');
    await t.ensureVisible(find.text('去背'));
    await settle(t, 3);
    await t.tap(find.text('去背'));
    await settle(t, 6);
    await t.tap(find.byType(Switch));
    await settle(t, 10);
    await t.tap(find.text('純色'));
    await settle(t, 6);
    await snap(t, 'cut_editor_sheet.png');
  });
}
