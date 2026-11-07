// 快速 Vlog 的截圖工具（不是回歸測試）。
//
// 真的佈景、真的字體（NotoSansTC＋Material Icons）、iPhone 14 視窗
// （390×844、DPR 3、安全區 47/34）。走使用者的路：首頁＋開始 → 快速 Vlog
// 選單那一列；剪輯頁用 videoPaths＋vlogEntry 進場（中繼資料由假通道回），
// 拍每段膠囊、每段表、選一段＝這段、這段表、自訂段、全部統一：
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/vlog_shot_tool.dart
//
// 預覽是合成播放器的貼圖，測試裡畫不出影片內容（黑的）；這裡看的是版面。
// 沒設環境變數時整支略過。檔名沒有 _test 結尾，整批 flutter test 也不會撿它。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/home_screen.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';
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

/// 五支「影片」各一種顏色的天空／地面
const _scenes = [
  (sky: 0xFF9CC7E0, ground: 0xFFD9C79C),
  (sky: 0xFFF2B98B, ground: 0xFF6E8B5A),
  (sky: 0xFF2C3E66, ground: 0xFF1D2433),
  (sky: 0xFFBFD9C8, ground: 0xFF8C6E5A),
  (sky: 0xFFE6D3E8, ground: 0xFFA5B5C9),
];

/// 五支的長度（第三支不到 2 秒）
const _durs = [12.0, 8.0, 1.4, 20.0, 6.0];

Future<Uint8List> _scene(int i) async {
  const w = 640.0, h = 360.0;
  final s = _scenes[i % _scenes.length];
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, w, h * 0.62),
    Paint()..color = Color(s.sky),
  );
  c.drawRect(
    const Rect.fromLTWH(0, h * 0.62, w, h * 0.38),
    Paint()..color = Color(s.ground),
  );
  c.drawCircle(
    Offset(w * (0.25 + 0.12 * i), h * 0.3),
    h * 0.09,
    Paint()..color = const Color(0xFFFFF4D6),
  );
  final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
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

  final frames = <Uint8List>[];
  late Directory dir;
  String p(int i) => '${dir.path}${Platform.pathSeparator}v$i.mp4';

  setUpAll(() async {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    dir = Directory.systemTemp.createTempSync('markcut_vlog_shot_');
    for (var i = 0; i < _durs.length; i++) {
      File(p(i)).writeAsStringSync('video $i');
    }
    WorkFiles.supportDirOverride = dir;
    WorkFiles.holdSweep = false;
    mockEditorPlugins(b, tempDir: dir);
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
    for (var i = 0; i < _scenes.length; i++) {
      frames.add(await _scene(i));
    }
    int indexOf(String path) {
      final m = RegExp(r'v(\d)').allMatches(path).lastOrNull;
      return m == null ? 0 : int.parse(m.group(1)!);
    }

    // 抽幀：照檔名回那一支的顏色
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/frames'),
      (call) async {
        if (call.method != 'frameAt') return null;
        final path = (call.arguments as Map)['path'] as String? ?? '';
        return frames[indexOf(path) % frames.length];
      },
    );
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/prep'),
      (call) async {
        switch (call.method) {
          case 'available':
            return true;
          case 'probeLite':
            final i = indexOf(call.arguments as String);
            return <String, dynamic>{
              'w': 1920,
              'h': 1080,
              'codec': 'avc1',
              'rotated': false,
              'sdr709': true,
              'durSec': _durs[i],
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

  tearDownAll(() {
    WorkFiles.supportDirOverride = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({kHomeProfileHintKey: true});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    Diag.playerLayer.value = false;
  });

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

  Widget app(Widget home) => RepaintBoundary(
    key: _shotKey,
    child: MaterialApp(
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      locale: const Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
        countryCode: 'TW',
      ),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hant',
          countryCode: 'TW',
        ),
        Locale('zh', 'TW'),
        Locale('zh'),
        Locale('en'),
      ],
      home: home,
    ),
  );

  testWidgets('首頁＋開始：快速 Vlog 那一列', (t) async {
    phone(t);
    await t.pumpWidget(app(const LightPage(child: HomeScreen())));
    await settle(t, 15);
    await t.tap(find.text('開始'));
    await settle(t, 15);
    await snap(t, 'vlog_0_home_menu.png');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('剪輯頁：每段、這段、自訂、全部統一', (t) async {
    phone(t);
    await t.pumpWidget(
      app(
        VideoEditorScreen(
          videoPaths: [for (var i = 0; i < _durs.length; i++) p(i)],
          vlogEntry: true,
        ),
      ),
    );
    await settle(t, 80);
    await snap(t, 'vlog_1_entry.png');

    Future<void> slide(double to) async {
      final s = t.widget<Slider>(
        find.byKey(const ValueKey('vlog-sheet-slider')),
      );
      s.onChangeStart!(s.value);
      s.onChanged!(to);
      s.onChangeEnd!(to);
      await settle(t, 10);
    }

    Future<void> close() async {
      await t.tapAt(const Offset(195, 60));
      await settle(t, 10);
    }

    await t.tap(find.byKey(const ValueKey('vlog-pill')));
    await settle(t, 10);
    await snap(t, 'vlog_2_sheet.png');
    await close();

    final lane = modelOf(t).onTrack(0);
    editorOf(t).onSelect(lane[1].id);
    await settle(t, 10);
    await snap(t, 'vlog_3_selected.png');
    await t.tap(find.byKey(const ValueKey('vlog-pill')));
    await settle(t, 10);
    await slide(3.5);
    await snap(t, 'vlog_4_clip_sheet.png');
    await close();
    await snap(t, 'vlog_5_custom_selected.png');

    editorOf(t).onSelect(-1);
    await settle(t, 10);
    await snap(t, 'vlog_6_custom.png');
    await t.tap(find.byKey(const ValueKey('vlog-pill')));
    await settle(t, 10);
    await snap(t, 'vlog_7_unify.png');
    await close();

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
    await t.pump(const Duration(seconds: 3));
  });
}
