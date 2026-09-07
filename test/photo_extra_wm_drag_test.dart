import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/photo_editor_screen.dart';
import 'package:markcut/widgets/watermark_layer.dart';

Future<Uint8List> _png(Color c, int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = c,
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

/// 照片解碼是非同步的，等它畫出來（跟 photo_mosaic_drag_test 同一套）
Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _open(WidgetTester t, Uint8List photo, {WatermarkSettings? wm}) {
  t.view.physicalSize = const Size(1200, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  return t.pumpWidget(
    MaterialApp(
      home: PhotoEditorScreen(
        photo: XFile.fromData(photo, name: 'p.png', mimeType: 'image/png'),
        initialWatermark: wm,
      ),
    ),
  );
}

/// 畫面上的每一層浮水印（第 0 層＝主浮水印，之後依序是額外組）
List<WatermarkSettings> _layers(WidgetTester t) => [
  for (final w in t.widgetList<WatermarkLayer>(find.byType(WatermarkLayer)))
    w.settings,
];

Rect _canvas(WidgetTester t) => t.getRect(find.byType(WatermarkLayer).first);

/// 有沒有琥珀選取框（主浮水印的框由 WmFrameOverlay 畫）
bool _mainFramed(WidgetTester t) => find
    .descendant(
      of: find.byType(WmFrameOverlay),
      matching: find.byType(DecoratedBox),
    )
    .evaluate()
    .isNotEmpty;

/// 面板：切到「文字」分頁、按「再加一組浮水印」，把跳出來的編輯面板關掉
Future<void> _addExtraViaPanel(WidgetTester t) async {
  await t.tap(find.text('文字').first);
  await _settle(t);
  final add = find.byTooltip('再加一組浮水印');
  await t.ensureVisible(add);
  await _settle(t);
  await t.tap(add);
  await _settle(t);
  expect(find.text('刪除這組'), findsOneWidget, reason: '加了一組會直接開它的編輯面板');
  await t.tapAt(const Offset(600, 60)); // 點面板外關閉
  await _settle(t);
  expect(find.text('刪除這組'), findsNothing);
}

/// 從 [from] 起手、往右下拖 12 步（每步 8px，共 96px）
Future<void> _dragFrom(WidgetTester t, Offset from) async {
  final g = await t.startGesture(from);
  await t.pump(const Duration(milliseconds: 20));
  for (var i = 0; i < 12; i++) {
    await g.moveBy(const Offset(8, 8));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await t.pump();
}

Future<void> _drainHint(WidgetTester t) => t.pump(const Duration(seconds: 3));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 迴歸守門：「更多浮水印」加了兩組，兩組的文字重疊；在清單點第一組
  //（選取它、面板開了再關），從重疊處拖——三組都不動。
  //
  // 成因跟 c471ff1 修過的「馬賽克被文字壓住拖不動」同一型：後加的那組
  // 疊在上面、HitTestBehavior.opaque，選了別組時它雖然不註冊拖曳
  //（panAllowed），命中測試照樣停在它身上；而整面的「選取路由」以前
  // 只認主浮水印（_wmPart）跟馬賽克，額外組被選時沒有人接手
  testWidgets('照片：兩組額外浮水印重疊，選了下面那組從重疊處拖得動它', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);
    await _addExtraViaPanel(t);
    await _addExtraViaPanel(t);
    final layers = _layers(t);
    expect(layers.length, 3);
    final main = layers[0], e0 = layers[1], e1 = layers[2];
    final before = [for (final l in layers) (l.text.x, l.text.y)];

    // 選第一組：清單那一列（開編輯面板＝選取它），再把面板關掉
    final row = find.text('點我編輯');
    expect(row, findsNWidgets(2));
    await t.tap(row.first);
    await _settle(t);
    expect(find.text('刪除這組'), findsOneWidget);
    await t.tapAt(const Offset(600, 60));
    await _settle(t);

    // 從兩組文字都蓋到的地方起手（第一組的框裡、也在第二組的框裡）：
    // 兩組中心的中點一定同時落在兩個框裡（框比彼此的位移大）
    final r = _canvas(t);
    final mid = Offset(
      r.left + r.width * (e0.text.x + e1.text.x) / 2,
      r.top + r.height * (e0.text.y + e1.text.y) / 2,
    );
    await _dragFrom(t, mid);

    expect(e0.text.x, greaterThan(before[1].$1 + 0.05), reason: '選取中的那組要跟著手指走');
    expect(e0.text.y, greaterThan(before[1].$2 + 0.05));
    expect((e1.text.x, e1.text.y), before[2], reason: '蓋在上面、沒被選的那組不能動');
    expect((main.text.x, main.text.y), before[0], reason: '主浮水印不能動');
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 每一組都從「主浮水印 +0.08」算位置，連加兩組就完全疊在一起——
  // 第二組要接在上一組後面錯開
  testWidgets('照片：連加兩組額外浮水印，位置要錯開、不能疊在同一個點', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);
    await _addExtraViaPanel(t);
    await _addExtraViaPanel(t);
    final layers = _layers(t);
    final e0 = layers[1].text, e1 = layers[2].text;
    expect((e0.x, e0.y), isNot((e1.x, e1.y)), reason: '兩組不能落在同一點');
    expect(e1.x, greaterThan(e0.x));
    expect(e1.y, greaterThan(e0.y));
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 迴歸守門：文字／圖片以前掛著 onDoubleTap（雙擊＝回正中央＋重設大小）。
  // 提示寫著「再點一次選下面那層」，照做快速連點兩下就被雙擊辨識器吃掉
  // ——文字被搬回中央、字級變預設，往下鑽根本沒發生；同一個辨識器也讓
  // 每一次單點都要等 300ms 才成立
  testWidgets('照片：單點立刻選到文字（沒有雙擊的 300ms 延遲）', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);
    expect(_mainFramed(t), isFalse);
    final r = _canvas(t);
    await t.tapAt(r.center);
    // 兩格（<100ms）：選取框就要出現
    await t.pump(const Duration(milliseconds: 40));
    await t.pump(const Duration(milliseconds: 40));
    expect(_mainFramed(t), isTrue, reason: '單點不該被雙擊辨識器延遲 300ms');
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('照片：快速連點兩下不會把文字搬回中央、也不會重設大小', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    final wm = WatermarkSettings();
    wm.text
      ..x = 0.3
      ..y = 0.3
      ..sizeFrac = 0.2;
    await _open(t, photo, wm: wm);
    await _settle(t, 20);
    final live = _layers(t).first.text;
    final r = _canvas(t);
    final at = Offset(r.left + r.width * 0.3, r.top + r.height * 0.3);
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 150));
    await t.tapAt(at);
    await _settle(t);
    expect((live.x, live.y), (0.3, 0.3), reason: '連點不是雙擊，位置不能動');
    expect(live.sizeFrac, 0.2, reason: '大小也不能被重設');
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 最上層的點擊判定以前用「未旋轉的外框」：轉了 90 度的長文字，點在
  // 字的正上方（框外）選不到，點在字旁邊的空白（框內）反而選到
  testWidgets('照片：旋轉 90 度的長文字，點擊判定跟著轉', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    final wm = WatermarkSettings();
    wm.text
      ..text = '@ABCDEFGHIJKL'
      ..sizeFrac = 0.08
      ..rotation = 90;
    await _open(t, photo, wm: wm);
    await _settle(t, 20);
    final r = _canvas(t);
    final c = r.center;
    // 字級＝短邊 8%；未旋轉的框：寬≈13 字、高≈1 字。轉 90 度後真正
    // 佔的是「窄而高」的一條——正右方 3 個字級的地方在舊框裡、
    // 但不在字上
    final fs = r.height * 0.08;
    await t.tapAt(Offset(c.dx + fs * 3, c.dy));
    await t.pump(const Duration(milliseconds: 40));
    await t.pump(const Duration(milliseconds: 40));
    expect(_mainFramed(t), isFalse, reason: '點在轉走的空白處不該選到');

    // 正下方 3 個字級：在字上（轉 90 度後是直的），舊框判定不到
    await t.tapAt(Offset(c.dx, c.dy + fs * 3));
    await t.pump(const Duration(milliseconds: 40));
    await t.pump(const Duration(milliseconds: 40));
    expect(_mainFramed(t), isTrue, reason: '點在轉過去的字上要選到');
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });
}
