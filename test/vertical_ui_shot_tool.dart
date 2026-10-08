// 直式切換的介面截圖（產圖工具，不是回歸測試）：浮水印面板的文字卡、
// 文字素材的編輯視窗（連同上面的預覽畫面），橫式／直式各拍一張。
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/vertical_ui_shot_tool.dart
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

  testWidgets('面板文字卡 → panel_h.png / panel_v.png', (t) async {
    phone(t);
    final settings = WatermarkSettings(texts: [TextMark(text: '@我的浮水印\n攝影日常')]);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: SafeArea(
              child: WatermarkPanel(settings: settings, onChanged: () {}),
            ),
          ),
        ),
      ),
    );
    await _settle(t);
    await t.tap(find.text('文字').first);
    await _settle(t, 12);
    final direction = find.byKey(const ValueKey('watermark-text-direction'));
    await t.ensureVisible(direction);
    await t.drag(find.byType(Scrollable).last, const Offset(0, 330));
    await _settle(t);
    await snap(t, 'panel_h');
    await t.tap(find.descendant(of: direction, matching: find.text('直式')));
    await _settle(t);
    await snap(t, 'panel_v');
  });

  testWidgets('文字素材編輯視窗 → clip_h.png / clip_v.png', (t) async {
    phone(t);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          // 全域浮水印關掉：畫面上只留文字素材，看得清楚
          home: VideoEditorScreen(
            blank: true,
            initialWatermark: WatermarkSettings(text: TextMark(enabled: false)),
          ),
        ),
      ),
    );
    await _settle(t, 5);
    late TimelineModel tl;
    VideoEditorScreen.debugTimeline!((m) {
      tl = m;
      m.sources.add(
        MediaSource(
          path: '',
          name: '@我的浮水印\n攝影日常',
          kind: ClipKind.text,
          duration: 3600,
          textStyle: TextMark(text: '@我的浮水印\n攝影日常', sizeFrac: 0.07, opacity: 1),
        ),
      );
      m.clips.add(
        TimelineClip(
          id: m.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 8,
          offset: 0,
          track: 0,
          px: 0.5,
          py: 0.5,
        ),
      );
    });
    await _settle(t, 15);
    final timeline = t.widget<TimelineEditor>(find.byType(TimelineEditor));
    timeline.onTapSelectedClip!(tl.clips[0].id);
    await _settle(t, 15);
    await snap(t, 'clip_h');
    final direction = find.byKey(const ValueKey('clip-text-direction'));
    await t.ensureVisible(direction);
    await t.tap(find.descendant(of: direction, matching: find.text('直式')));
    await _settle(t, 10);
    await snap(t, 'clip_v');
    final align = find.byKey(const ValueKey('clip-text-alignment'));
    await t.tap(find.descendant(of: align, matching: find.text('置中')));
    await _settle(t, 10);
    await snap(t, 'clip_v_center');
    Navigator.of(t.element(direction)).pop();
    await _settle(t, 20);
  });
}
