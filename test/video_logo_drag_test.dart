import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/widgets/watermark_layer.dart';
import 'package:markcut/widgets/watermark_panel.dart';

Future<Uint8List> _png(Color c, int side) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..color = c,
  );
  final img = await rec.endRecording().toImage(side, side);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

/// 圖片解碼是非同步的，等它畫出來。
/// 不用 pumpAndSettle：編輯頁上永遠有東西在動（時間軸的提示、
/// 播放頭），會一路等到 10 分鐘逾時
Future<void> _settle(WidgetTester t, [int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 分頁切換／版面重排：跑掉固定幾幀就好（理由同 _settle）
Future<void> _tick(WidgetTester t, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 真實情境：文字（預設就在正中央）跟一張剛加進來的圖片（也在正中央）。
///
/// 畫 PNG 一定要包在 runAsync 裡：PictureRecorder → toImage → toByteData
/// 全都要真的事件迴圈，在假時鐘下直接 await 會讓後面第一個 pumpWidget
/// 永遠等不到微任務清空，整支測試卡到逾時（踩過）
Future<WatermarkSettings> _settings(WidgetTester t) async {
  late Uint8List bytes;
  await t.runAsync(() async {
    bytes = await _png(const Color(0xFFFF0000), 100);
  });
  final s = WatermarkSettings();
  s.logo
    ..enabled = true
    ..bytesValue = bytes
    ..sizeFrac = 0.32
    ..x = 0.5
    ..y = 0.5;
  return s;
}

/// 空白專案（不需要影片播放器）＋帶一份浮水印進場，
/// 切到「浮水印」分頁、再切到面板的「圖片」區、點那張縮圖
Future<void> _openPanelAndTapLogoThumb(WidgetTester t) async {
  await t.tap(find.widgetWithText(Tab, '浮水印'));
  await _tick(t);
  await t.tap(find.widgetWithText(InkWell, '圖片'));
  await _tick(t);
  final thumb = find.descendant(
    of: find.byType(WatermarkPanel),
    matching: find.byType(Image),
  );
  expect(thumb, findsOneWidget, reason: '圖片分頁裡應該只有那一張縮圖是 Image');
  await t.tap(thumb);
  await _tick(t);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1100, 2200);
    v.devicePixelRatio = 1.0;
    // 測試環境沒有這些原生外掛，擋掉不然頁面一開就丟例外
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

  // 迴歸守門：影片編輯頁「點了面板的圖片縮圖（琥珀亮框）之後，
  // 圖片在預覽上動不了」。
  //
  // 成因跟批次那條同一個（見 test/batch_logo_drag_test.dart）：預覽的
  // 拖曳／捏合全由「選取路由」統一收，而路由只認畫面自己的選取
  //（_wmSel＋_wmPart）——點縮圖以前只改 settings.activeLogo，畫面
  // 從來不知道使用者選的是圖片。進場預選的是文字，於是拖曳跑去搬
  // 文字；先點過任何片段（_wmSel 被清掉）的話路由整個不掛，手指
  // 就被文字那層 opaque 的判定（畫在圖片之上、預設又比圖片寬）吃光
  testWidgets('影片：在面板選了圖片之後，預覽上拖得動它（文字不會被拖走）', (t) async {
    final s = await _settings(t);
    await t.pumpWidget(
      MaterialApp(home: VideoEditorScreen(blank: true, initialWatermark: s)),
    );
    await _settle(t);

    final layerFinder = find.byType(WatermarkLayer);
    expect(layerFinder, findsOneWidget);
    WatermarkSettings live() => t.widget<WatermarkLayer>(layerFinder).settings;

    await _openPanelAndTapLogoThumb(t);

    final logoBefore = (live().logo.x, live().logo.y);
    final textBefore = (live().text.x, live().text.y);

    // 從圖片中心往右下拖（正是被文字蓋住的那一塊）
    final r = t.getRect(layerFinder);
    final start = Offset(
      r.left + r.width * logoBefore.$1,
      r.top + r.height * logoBefore.$2,
    );
    final step = Offset(r.width * 0.02, r.height * 0.02);
    final g = await t.startGesture(start);
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(step);
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump();

    expect(
      live().logo.x,
      greaterThan(logoBefore.$1 + 0.05),
      reason: '選取中的圖片要跟著手指走',
    );
    expect(live().logo.y, greaterThan(logoBefore.$2 + 0.05));
    // 拖的是圖片，文字一動都不能動
    expect(live().text.x, textBefore.$1);
    expect(live().text.y, textBefore.$2);

    // 放手會排合成重建（350ms）與存草稿的計時器，跑掉再收尾——
    // 不然測試結束時的「還有計時器沒燒完」斷言會擋下來
    await _settle(t, 25);
  });

  // 同一個根因的第二個症狀：捏合縮放／旋轉也只作用在「畫面上被選取
  // 的部件」（_pickPinchTarget 讀 _wmPart，而且整段只在 _wmSel 為真時
  // 才跑）。面板選了圖片卻沒告訴畫面，兩指就跑去縮放／旋轉文字
  testWidgets('影片：在面板選了圖片之後，兩指縮放與旋轉動的是圖片（文字不變）', (t) async {
    final s = await _settings(t);
    await t.pumpWidget(
      MaterialApp(home: VideoEditorScreen(blank: true, initialWatermark: s)),
    );
    await _settle(t);

    final layerFinder = find.byType(WatermarkLayer);
    WatermarkSettings live() => t.widget<WatermarkLayer>(layerFinder).settings;

    await _openPanelAndTapLogoThumb(t);

    final logoSize0 = live().logo.sizeFrac;
    final textSize0 = live().text.sizeFrac;
    final c = t.getRect(layerFinder).center;

    // 兩指張開（起手就要超過 12px 門檻，見 _armPreviewPinch）
    var a = await t.startGesture(c + const Offset(-40, 0));
    var b = await t.startGesture(c + const Offset(40, 0));
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < 8; i++) {
      await a.moveBy(const Offset(-5, 0));
      await b.moveBy(const Offset(5, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await t.pump();

    expect(
      live().logo.sizeFrac,
      greaterThan(logoSize0 * 1.5),
      reason: '選取中的圖片要跟著兩指變大',
    );
    expect(live().text.sizeFrac, textSize0, reason: '文字不能一起被縮放');

    // 兩指轉 90 度（距離不變＝只轉不縮）
    final rot0 = live().logo.rotation;
    a = await t.startGesture(c + const Offset(-40, 0));
    b = await t.startGesture(c + const Offset(40, 0));
    await t.pump(const Duration(milliseconds: 20));
    await a.moveTo(c + const Offset(0, -40));
    await b.moveTo(c + const Offset(0, 40));
    await t.pump(const Duration(milliseconds: 16));
    await a.up();
    await b.up();
    await t.pump();

    expect(
      (live().logo.rotation - rot0).abs(),
      greaterThan(45),
      reason: '選取中的圖片要跟著兩指轉',
    );
    expect(live().text.rotation, 0, reason: '文字不能一起被轉');

    // 同上：放手排的計時器要跑掉
    await _settle(t, 25);
  });
}
