// 直式文字：資料存讀、共用畫家的直排（一字一格、欄由右往左、對齊＝
// 上中下）、底色留白，以及浮水印面板文字卡的「橫式｜直式」切換。
// 文字素材編輯視窗的切換在 video_editor_gesture_rebuild_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/text_mark_painter.dart';
import 'package:markcut/widgets/watermark_panel.dart';

/// 畫一顆文字，回傳不透明像素的列範圍（只看 x 在 [x0, x1) 的部分）
Future<({int top, int bottom})?> _inkRows(
  TextMark t,
  double fontSize,
  int w,
  int h, {
  required int x0,
  required int x1,
}) async {
  final rec = ui.PictureRecorder();
  paintMarkGlyphs(ui.Canvas(rec), t, fontSize, ui.Offset.zero);
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  img.dispose();
  pic.dispose();
  int? top, bottom;
  for (var y = 0; y < h; y++) {
    for (var x = x0; x < x1; x++) {
      if (px.getUint8((y * w + x) * 4 + 3) > 40) {
        top ??= y;
        bottom = y;
        break;
      }
    }
  }
  return top == null ? null : (top: top, bottom: bottom!);
}

TextMark _plain(String text, {TextAlign align = TextAlign.left}) => TextMark(
  text: text,
  vertical: true,
  alignment: align,
  shadow: false,
  weight: 0,
  opacity: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // 真的思源黑體：中文字身框、直排標點都要真字型才量得準
    final data = File('assets/fonts/NotoSansTC.ttf').readAsBytesSync();
    final loader = FontLoader('NotoSansTC')
      ..addFont(Future.value(ByteData.view(data.buffer)));
    await loader.load();
  });

  tearDown(clearGlyphCache);

  test('直式跟著複製、JSON 走；舊草稿沒有這個欄位＝橫式', () {
    expect(TextMark.fromJson({'text': 'a'}).vertical, isFalse);
    expect(TextMark().toJson().containsKey('vertical'), isFalse);
    final t = TextMark(text: '直式', vertical: true);
    expect(t.toJson()['vertical'], isTrue);
    expect(TextMark.fromJson(t.toJson()).vertical, isTrue);
    expect(t.copy().vertical, isTrue);
    final s = WatermarkSettings(texts: [TextMark(), t]);
    final back = WatermarkSettings.fromJson(s.toJson());
    expect(back.texts.map((e) => e.vertical), [false, true]);
    expect(
      WatermarkPreset.decode(
        WatermarkPreset(name: 'v', settings: s).encode(),
      ).settings.texts[1].vertical,
      isTrue,
    );
  });

  test('一字一格往下排：格高＝字級×(1＋間距)，換行往左開一欄', () {
    const fs = 40.0;
    final one = measureMark(_plain('浮水印'), fs);
    expect(one.width, fs);
    expect(one.height, fs * 3);
    final two = measureMark(_plain('浮水印\n剪輯'), fs);
    expect(two.width, fs * 2 + fs * kVerticalColumnGap);
    expect(two.height, fs * 3);
    expect(measureMark(_plain('浮水印')..spacing = 0.5, fs).height, fs * 1.5 * 3);
    // 半形空白半格、全形空白一整格
    expect(measureMark(_plain('浮 印'), fs).height, fs * 2.5);
    expect(measureMark(_plain('浮　印'), fs).height, fs * 3);
    // 一個字素叢集（國旗＝兩個碼位）只佔一格
    expect(measureMark(_plain('🇹🇼'), fs).height, fs);
    // 橫式完全不受影響：還是橫的長條
    final horizontal = measureMark(_plain('浮水印')..vertical = false, fs);
    expect(horizontal.width, greaterThan(horizontal.height * 2));
  });

  test('第一行在最右邊；短的那欄照對齊靠上／置中／靠下', () async {
    const fs = 20.0;
    // 右欄三個字、左欄只有一個「一」（一條橫線，剛好標出格子中心）
    final t = _plain('三三三\n一');
    final m = measureMark(t, fs);
    final w = m.width.ceil() + 2, h = m.height.ceil() + 2;
    final mid = (m.width / 2).round();
    final right = (await _inkRows(t, fs, w, h, x0: mid, x1: w))!;
    final left = (await _inkRows(t, fs, w, h, x0: 0, x1: mid))!;
    expect(right.bottom - right.top, greaterThan(fs * 2.4));
    expect(left.bottom - left.top, lessThan(fs * 0.4));
    for (final (align, cell) in [
      (TextAlign.left, 0),
      (TextAlign.center, 1),
      (TextAlign.right, 2),
    ]) {
      t.alignment = align;
      final ink = (await _inkRows(t, fs, w, h, x0: 0, x1: mid))!;
      final center = (ink.top + ink.bottom) / 2;
      // 「一」落在第 cell 格的中間（字身框中心對格子中心）
      expect(center, closeTo(fs * cell + fs / 2, fs * 0.15), reason: '$align');
    }
  });

  test('切直式要重畫、重新量（排版快取的鍵有直式）', () {
    final t = _plain('浮水印')..vertical = false;
    final old = MarkGlyphPainter(t, 20);
    final h = measureMark(t, 20);
    t.vertical = true;
    expect(MarkGlyphPainter(t, 20).shouldRepaint(old), isTrue);
    final v = measureMark(t, 20);
    expect(v.height, greaterThan(h.height));
    expect(v.width, lessThan(h.width));
  });

  test('底色留白：橫式上下少（行高本來就有空），直式四邊一樣', () {
    final h = markBgPadding(TextMark(bgPad: 1), 100);
    expect(h.h, closeTo(35, 1e-9));
    expect(h.v, closeTo(18, 1e-9));
    final v = markBgPadding(TextMark(bgPad: 2, vertical: true), 100);
    expect(v.h, closeTo(70, 1e-9));
    expect(v.v, closeTo(70, 1e-9));
  });

  testWidgets('文字卡：橫式｜直式切換，直式的對齊變成靠上／置中／靠下', (t) async {
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(320, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final settings = WatermarkSettings(texts: [TextMark(text: '直式\n浮水印')]);
    WatermarkSettings? undo;
    var changes = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: WatermarkPanel(
            settings: settings,
            showAnimation: true,
            onBeforeChange: () => undo = settings.copy(),
            onChanged: () => changes++,
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(const Duration(milliseconds: 30));
    }
    await t.tap(find.text('文字').first);
    await t.pump(const Duration(milliseconds: 400));
    final direction = find.byKey(const ValueKey('watermark-text-direction'));
    final align = find.byKey(const ValueKey('watermark-text-alignment'));
    final input = find.byKey(const ValueKey('watermark-text-input'));
    await t.ensureVisible(direction);
    expect(t.widget<SegmentedButton<bool>>(direction).selected, {false});
    expect(
      find.descendant(of: align, matching: find.text('靠左')),
      findsOneWidget,
    );

    await t.tap(find.descendant(of: direction, matching: find.text('直式')));
    await t.pump();
    expect(settings.text.vertical, isTrue);
    expect(changes, 1);
    expect(undo!.text.vertical, isFalse, reason: '上一步要回得到橫式');
    expect(
      find.descendant(of: align, matching: find.text('靠上')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: align, matching: find.text('靠下')),
      findsOneWidget,
    );
    expect(find.descendant(of: align, matching: find.text('靠左')), findsNothing);

    await t.ensureVisible(align);
    await t.tap(find.descendant(of: align, matching: find.text('靠下')));
    await t.pump();
    expect(settings.text.alignment, TextAlign.right);
    // 直式的對齊是上下，打字的框照常靠左
    expect(t.widget<TextField>(input).textAlign, TextAlign.left);

    await t.ensureVisible(direction);
    await t.tap(find.descendant(of: direction, matching: find.text('橫式')));
    await t.pump();
    expect(settings.text.vertical, isFalse);
    expect(
      find.descendant(of: align, matching: find.text('靠右')),
      findsOneWidget,
    );
    expect(t.widget<TextField>(input).textAlign, TextAlign.right);
    expect(t.takeException(), isNull);
  });
}
