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

/// 照片解碼是非同步的，等它畫出來（跟 photo_editor_test 同一套）
Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump(const Duration(milliseconds: 60));
  }
}

/// 開照片編輯器。面板是分頁 lazy build 的，畫面太矮下面的卡片根本
/// 不會被建出來，所以把視窗拉高
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

/// 畫面上實際在用的那份設定（編輯器把 initialWatermark 拷貝了一份，
/// 從外面拿不到；主浮水印圖層拿的就是那一份）
WatermarkSettings _live(WidgetTester t) =>
    t.widget<WatermarkLayer>(find.byType(WatermarkLayer).first).settings;

/// 預覽畫布（主浮水印圖層鋪滿它）
Rect _canvas(WidgetTester t) => t.getRect(find.byType(WatermarkLayer).first);

/// 照測試者的操作：上方導覽列切到「馬賽克」→ 按＋加一塊
///（新的一塊會被選起來、畫琥珀框）
Future<void> _addMosaicViaPanel(WidgetTester t) async {
  await t.tap(find.text('馬賽克').first);
  await _settle(t);
  final add = find.byTooltip('加一塊馬賽克');
  expect(add, findsOneWidget, reason: '馬賽克分頁上要有那顆＋');
  await t.tap(add);
  await _settle(t);
  expect(_live(t).mosaics.length, 1);
  // 清單上那一列（測試者截圖裡亮著的那一列），再點一次＝選取它
  final tile = find.text('第 1 塊 · 像素化');
  expect(tile, findsOneWidget);
  await t.tap(tile);
  await _settle(t);
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

/// 讓 showHint 的 2.4 秒計時器跑完，不然測試框架會抱怨還有 timer
Future<void> _drainHint(WidgetTester t) => t.pump(const Duration(seconds: 3));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 迴歸守門（測試者回報「馬賽克無法移動」，iOS TestFlight）：
  // 照片編輯器在馬賽克分頁加了一塊、清單上那一列亮著、畫面上有琥珀框，
  // 在畫面上拖它卻一動也不動。
  //
  // 成因：新的一塊放在正中央，預設文字「@我的浮水印」也在正中央，
  // 手指自然落在文字上。文字圖層畫在馬賽克層之上而且 HitTestBehavior
  // .opaque——馬賽克被選取時它雖然不註冊拖曳（panAllowed 說「讓給選取
  // 路由」），命中測試照樣停在它身上，指標根本到不了下面的馬賽克；
  // 而能讓被選的東西在整個預覽上都拖得動的「選取路由」只在選了浮水印
  // 部件時才掛，選了馬賽克時沒有人接手
  testWidgets('照片：加了馬賽克（預設文字壓在上面），在畫面上拖得動它、文字不動', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);

    // 真實情境：預設文字在正中央、新加的馬賽克也在正中央
    expect(_live(t).text.x, 0.5);
    expect(_live(t).text.y, 0.5);
    await _addMosaicViaPanel(t);
    final m = _live(t).mosaics.single;
    expect((m.x, m.y), (0.5, 0.5));

    // 從畫布正中央（馬賽克中心＝文字所在）往右下拖
    final r = _canvas(t);
    await _dragFrom(t, r.center);

    expect(m.x, greaterThan(0.5 + 0.05), reason: '選取中的馬賽克要跟著手指走');
    expect(m.y, greaterThan(0.5 + 0.05));
    // 拖的是馬賽克，文字一動都不能動
    expect(_live(t).text.x, 0.5);
    expect(_live(t).text.y, 0.5);
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 對照組：手指落在馬賽克上「沒被文字蓋到」的地方，本來就拖得動——
  // 壞的只有重疊那一塊，證明成因是命中測試被文字吃掉，不是拖曳本身
  testWidgets('照片：手指落在馬賽克沒被文字蓋到的地方，一樣拖得動', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);
    await _addMosaicViaPanel(t);
    final m = _live(t).mosaics.single;

    // 馬賽克是短邊 72% 的正方形，上緣在畫布高的 14%；文字只佔中間
    // 一條（字級短邊 12%）。畫布高 25% 處在馬賽克裡、離文字很遠
    final r = _canvas(t);
    await _dragFrom(t, Offset(r.center.dx, r.top + r.height * 0.25));

    expect(m.x, greaterThan(0.5 + 0.05));
    expect(m.y, greaterThan(0.5 + 0.05));
    expect(_live(t).text.x, 0.5);
    expect(_live(t).text.y, 0.5);
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 修了馬賽克不能把浮水印弄壞：點文字把選取切回文字之後，
  // 文字照樣拖得動、馬賽克不動
  testWidgets('照片：馬賽克在場時，選了文字還是拖得動文字', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);
    await _addMosaicViaPanel(t);
    final m = _live(t).mosaics.single;

    // 點正中央：最上層是文字，選取切到文字（馬賽克的選取跟著取消）
    final r = _canvas(t);
    await t.tapAt(r.center);
    await _settle(t);
    // 文字有選取＝它的琥珀框在畫（框是外層 WmFrameOverlay 在畫）
    expect(find.byType(WmFrameOverlay), findsOneWidget);

    await _dragFrom(t, r.center);
    expect(_live(t).text.x, greaterThan(0.5 + 0.05), reason: '選取中的文字要跟著手指走');
    expect(_live(t).text.y, greaterThan(0.5 + 0.05));
    expect((m.x, m.y), (0.5, 0.5), reason: '拖的是文字，馬賽克不能動');
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 圖片那邊同一套規則：馬賽克選取中，整個預覽的拖曳都只動馬賽克
  //（手指從圖片上起手也一樣，跟「選了文字拖圖片會動文字」一致）；
  // 點了圖片把選取換過去之後，拖的就是圖片、馬賽克不動
  testWidgets('照片：馬賽克選取中從圖片上起手拖的是馬賽克；選了圖片就拖得動圖片', (t) async {
    late Uint8List photo, logoPng;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
      logoPng = await _png(const Color(0xFFFF0000), 100, 100);
    });
    // 圖片放左上角，離正中央的文字與馬賽克都遠
    final wm = WatermarkSettings();
    wm.logo
      ..enabled = true
      ..bytesValue = logoPng
      ..x = 0.12
      ..y = 0.12;
    await _open(t, photo, wm: wm);
    await _settle(t, 20);
    await _addMosaicViaPanel(t);
    final m = _live(t).mosaics.single;
    final lg = _live(t).logo;
    expect((lg.x, lg.y), (0.12, 0.12));

    final r = _canvas(t);
    Offset logoAt() => Offset(r.left + r.width * lg.x, r.top + r.height * lg.y);

    // 馬賽克選取中：從圖片上起手，動的是馬賽克
    await _dragFrom(t, logoAt());
    expect(m.x, greaterThan(0.5 + 0.05), reason: '選取中的馬賽克要跟著手指走');
    expect(m.y, greaterThan(0.5 + 0.05));
    expect((lg.x, lg.y), (0.12, 0.12), reason: '圖片不能被拖走');

    // 點圖片＝選取換到圖片（馬賽克取消選取）
    await t.tapAt(logoAt());
    await _settle(t);
    final mAfter = (m.x, m.y);
    await _dragFrom(t, logoAt());
    expect(lg.x, greaterThan(0.12 + 0.05), reason: '選取中的圖片要跟著手指走');
    expect(lg.y, greaterThan(0.12 + 0.05));
    expect((m.x, m.y), mAfter, reason: '拖的是圖片，馬賽克不能動');
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });
}
