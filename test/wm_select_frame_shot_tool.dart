// 選了浮水印預覽上要有琥珀框的截圖（產圖工具，不是回歸測試；回歸測試是
// wm_select_frame_test）。照使用者那條路拍：點過別的（取消選取）→ 底下
// 點「浮水印」分頁 → 文字頁 → 圖片頁；再拍浮水印素材（＋ → 浮水印）被選著
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/wm_select_frame_shot_tool.dart
//
// 沒設環境變數時整支略過。字型照 App（思源黑體＋Material 圖示）
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/timeline_editor.dart';
import 'package:markcut/widgets/watermark_panel.dart';

import 'editor_harness.dart' show solidPng;

final _shotKey = GlobalKey();

String? _materialIconsPath() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final exe = Platform.resolvedExecutable.replaceAll(
    String.fromCharCode(92),
    '/',
  );
  final i = exe.indexOf('/bin/cache/');
  for (final c in [
    if (root != null)
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    if (i >= 0)
      '${exe.substring(0, i)}'
          '/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  ]) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

Finder _nav(String label) => find
    .descendant(of: find.byType(WatermarkPanel), matching: find.text(label))
    .first;

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '截圖工具，要給輸出資料夾才會跑');
    return;
  }

  setUpAll(() async {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    Directory(out).createSync(recursive: true);
    for (final (family, path) in const [
      ('NotoSansTC', 'assets/fonts/NotoSansTC.ttf'),
      ('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf'),
      ('MarkcutTabExtraBold', 'assets/fonts/MarkcutTabExtraBold.ttf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
    final icons = _materialIconsPath();
    expect(icons, isNotNull, reason: '找不到 materialicons-regular.otf');
    final il = FontLoader('MaterialIcons')
      ..addFont(File(icons!).readAsBytes().then((b) => b.buffer.asByteData()));
    await il.load();
    for (final ch in const [
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/wakelock',
      'markcut/comp',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
  });

  Future<void> snap(WidgetTester t, String name) => t.runAsync(() async {
    final b =
        _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final im = await b.toImage(pixelRatio: 3);
    final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });

  void phone(WidgetTester t) {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);
  }

  Future<void> pumpEditor(WidgetTester t, WatermarkSettings wm) async {
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: VideoEditorScreen(blank: true, initialWatermark: wm),
        ),
      ),
    );
    await _settle(t, 15);
  }

  TimelineEditor timeline(WidgetTester t) =>
      t.widget<TimelineEditor>(find.byType(TimelineEditor));

  testWidgets('全域浮水印 → wmframe_0_deselected / _1_text / _2_logo', (t) async {
    phone(t);
    final wm = WatermarkSettings(
      text: TextMark(text: '買電腦', sizeFrac: 0.16, opacity: 1, y: 0.4),
    );
    wm.logo
      ..enabled = true
      ..y = 0.78
      ..sizeFrac = 0.18
      ..bytesValue = solidPng(230, 70, 60, size: 32);
    await pumpEditor(t, wm);
    // 使用者的現場：點過別的東西，浮水印就不是選取中了
    timeline(t).onSelect(-1);
    await _settle(t, 6);
    await snap(t, 'wmframe_0_deselected');

    await t.tap(find.widgetWithText(Tab, '浮水印'));
    await _settle(t, 15);
    await t.tap(_nav('文字'));
    await _settle(t, 10);
    await snap(t, 'wmframe_1_text');

    await t.tap(_nav('圖片'));
    await _settle(t, 10);
    await snap(t, 'wmframe_2_logo');
  });

  testWidgets('浮水印素材 → wmframe_3_clip / _4_clip_tab', (t) async {
    phone(t);
    await pumpEditor(t, WatermarkSettings(text: TextMark(text: '')));
    late int id;
    VideoEditorScreen.debugTimeline!((m) {
      m.sources.add(
        MediaSource(
          path: '',
          name: '買電腦',
          kind: ClipKind.wm,
          duration: 3600,
          wmStyle: WatermarkSettings(
            text: TextMark(text: '買電腦', sizeFrac: 0.16, opacity: 1, y: 0.4),
          ),
        ),
      );
      id = m.nextId();
      m.clips.add(
        TimelineClip(
          id: id,
          sourceIndex: m.sources.length - 1,
          trimStart: 0,
          trimEnd: 8,
          offset: 0,
          track: 0,
        ),
      );
    });
    await _settle(t, 10);
    timeline(t).onSelect(id);
    await _settle(t, 8);
    await snap(t, 'wmframe_3_clip');

    await t.tap(find.widgetWithText(Tab, '浮水印'));
    await _settle(t, 15);
    await t.tap(_nav('文字'));
    await _settle(t, 10);
    await snap(t, 'wmframe_4_clip_tab');
  });
}
