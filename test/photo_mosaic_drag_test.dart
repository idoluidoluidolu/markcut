import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/mosaic.dart';
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

/// 照測試者的操作：上方導覽列切到「馬賽克」→ 縮圖那排最後的虛線加號 →
/// 選單「圓圈」（10-25 換成跟馬賽克模式同一套：不選取、不畫框，新的一塊
/// 放在浮水印壓不到的地方）
Future<void> _addMosaicViaPanel(WidgetTester t) async {
  await t.tap(find.text('馬賽克').first);
  await _settle(t);
  final add = find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == '新增馬賽克',
  );
  expect(add, findsOneWidget, reason: '馬賽克卡上要有那顆虛線加號');
  await t.tap(add);
  await _settle(t);
  await t.tap(find.text('圓圈'));
  await _settle(t);
  expect(_live(t).mosaics.length, 1);
}

/// 一塊馬賽克的中心在畫面上的哪裡
Offset _at(WidgetTester t, PhotoMosaic m) {
  final r = _canvas(t);
  return Offset(r.left + m.x * r.width, r.top + m.y * r.height);
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

  // 迴歸守門（測試者回報「馬賽克無法移動」，iOS TestFlight）：舊版新的一塊
  // 放在正中央，預設文字「@我的浮水印」也在正中央，手指自然落在文字上——
  // 文字圖層畫在馬賽克層之上，命中測試停在它身上，指標到不了下面的馬賽克。
  // 舊版靠「選了馬賽克就整面拖它」的選取路由解；新版不選取，改成新的
  // 一塊放在浮水印壓不到的地方（_freeSpot 把浮水印的框也算進去）
  testWidgets('照片：新加的馬賽克不會被預設文字壓住，按在它身上拖得動、文字不動', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);

    // 真實情境：預設文字在正中央
    expect(_live(t).text.x, 0.5);
    expect(_live(t).text.y, 0.5);
    await _addMosaicViaPanel(t);
    final m = _live(t).mosaics.single;
    expect(m.oval, isTrue, reason: '新版一律圓圈');
    expect((m.x, m.y), isNot((0.5, 0.5)), reason: '放正中央會被預設文字壓住');
    final (x0, y0) = (m.x, m.y);

    await _dragFrom(t, _at(t, m));
    expect(m.x, greaterThan(x0 + 0.05), reason: '按在馬賽克身上要拖得動');
    expect(m.y, greaterThan(y0 + 0.05));
    // 拖的是馬賽克，文字一動都不能動
    expect(_live(t).text.x, 0.5);
    expect(_live(t).text.y, 0.5);
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 修了馬賽克不能把浮水印弄壞：點文字選起來之後，文字照樣拖得動、馬賽克不動
  testWidgets('照片：馬賽克在場時，選了文字還是拖得動文字', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);
    await _addMosaicViaPanel(t);
    final m = _live(t).mosaics.single;
    final before = (m.x, m.y);

    final r = _canvas(t);
    await t.tapAt(r.center);
    await _settle(t);
    await _dragFrom(t, r.center);
    expect(_live(t).text.x, greaterThan(0.5 + 0.05), reason: '選取中的文字要跟著手指走');
    expect(_live(t).text.y, greaterThan(0.5 + 0.05));
    expect((m.x, m.y), before, reason: '拖的是文字，馬賽克不能動');
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 選著文字時整個預覽的拖曳都歸文字（選取路由）。點一下馬賽克＝點的是
  // 別的東西，文字的選取要取消——不然之後在馬賽克上拖，動的還是文字
  testWidgets('照片：選著文字時點一下馬賽克，接著拖的就是馬賽克', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);
    await _addMosaicViaPanel(t);
    final m = _live(t).mosaics.single;

    await t.tapAt(_canvas(t).center); // 選文字
    await _settle(t);
    await t.tapAt(_at(t, m)); // 點馬賽克
    await _settle(t);
    final (x0, y0) = (m.x, m.y);
    await _dragFrom(t, _at(t, m));
    expect(m.x, greaterThan(x0 + 0.05), reason: '點過馬賽克，文字的選取要取消');
    expect(m.y, greaterThan(y0 + 0.05));
    expect(_live(t).text.x, 0.5, reason: '文字不能被拖走');
    expect(_live(t).text.y, 0.5);
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 圖片那邊同一套：沒選東西時按在馬賽克上拖的是馬賽克；點了圖片把選取
  // 換過去之後，拖的就是圖片、馬賽克不動
  testWidgets('照片：拖馬賽克不動圖片；選了圖片就拖得動圖片、馬賽克不動', (t) async {
    late Uint8List photo, logoPng;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
      logoPng = await _png(const Color(0xFFFF0000), 100, 100);
    });
    // 圖片放左上角，離正中央的文字遠
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

    final (x0, y0) = (m.x, m.y);
    await _dragFrom(t, _at(t, m));
    expect(m.x, greaterThan(x0 + 0.05), reason: '按在馬賽克身上要拖得動');
    expect((lg.x, lg.y), (0.12, 0.12), reason: '圖片不能被拖走');

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
