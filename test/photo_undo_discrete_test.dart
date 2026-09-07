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

Future<void> _open(WidgetTester t, Uint8List photo) {
  t.view.physicalSize = const Size(1200, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  return t.pumpWidget(
    MaterialApp(
      home: PhotoEditorScreen(
        photo: XFile.fromData(photo, name: 'p.png', mimeType: 'image/png'),
      ),
    ),
  );
}

WatermarkSettings _live(WidgetTester t) =>
    t.widget<WatermarkLayer>(find.byType(WatermarkLayer).first).settings;

/// 控制列上的上一步／重做鈕（onPressed 為 null＝灰掉）
IconButton _btn(WidgetTester t, IconData icon) =>
    t.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

Future<void> _drainHint(WidgetTester t) => t.pump(const Duration(seconds: 3));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 迴歸守門：_pushUndo 以前有一條「0.7 秒內不再拍快照」的全域節流。
  // 那是給連續滑桿用的（後來滑桿改在面板端合併成一步了），留在這裡
  // 只會吃掉離散動作：加一塊馬賽克、0.7 秒內按刪除——第二個動作沒拍到
  // 快照，「上一步」一次退兩步，加的那一塊直接消失
  testWidgets('照片：加馬賽克後立刻刪掉，上一步只退一步（馬賽克回來）', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);

    await t.tap(find.text('馬賽克').first);
    await _settle(t);
    await t.tap(find.byTooltip('加一塊馬賽克'));
    // 只等兩格（遠小於 0.7 秒的真實時間），模擬「加了馬上按刪除」。
    // 節流比的是 DateTime.now()（FakeAsync 假不了），所以這裡的
    // 間隔是真的壁鐘時間
    await _settle(t, 2);
    expect(_live(t).mosaics.length, 1);
    await t.tap(find.byTooltip('刪除'));
    await _settle(t, 2);
    expect(_live(t).mosaics.length, 0);

    await t.tap(find.byTooltip('上一步'));
    await _settle(t);
    expect(_live(t).mosaics.length, 1, reason: '上一步只該撤銷「刪除」，馬賽克要回來');

    // 再退一步：連「加」也撤掉
    await t.tap(find.byTooltip('上一步'));
    await _settle(t);
    expect(_live(t).mosaics.length, 0);
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 被節流吃掉的那一次 _pushUndo 也不會清重做堆疊：上一步之後 0.7 秒內
  // 做新編輯，「重做」還亮著，按下去會把剛做的新編輯默默丟掉
  testWidgets('照片：上一步之後立刻做新編輯，重做要作廢', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);

    await t.tap(find.text('馬賽克').first);
    await _settle(t);
    await t.tap(find.byTooltip('加一塊馬賽克'));
    await _settle(t);
    await t.tap(find.byTooltip('上一步'));
    await _settle(t, 2);
    expect(_live(t).mosaics.length, 0);
    expect(_btn(t, Icons.redo).onPressed, isNotNull, reason: '剛撤銷，重做要亮');

    // 0.7 秒內做一個新的離散編輯
    await t.tap(find.byTooltip('加一塊馬賽克'));
    await _settle(t, 2);
    expect(_live(t).mosaics.length, 1);
    expect(_btn(t, Icons.redo).onPressed, isNull, reason: '有新編輯，分支掉的未來要作廢');
    expect(_btn(t, Icons.undo).onPressed, isNotNull);
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });

  // 馬賽克樣式表：每個離散改動各拍一次快照，不是整張表開著只拍一次
  testWidgets('照片：馬賽克樣式表裡連換兩次樣式，上一步一次只退一次', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF888888), 900, 600);
    });
    await _open(t, photo);
    await _settle(t, 20);

    await t.tap(find.text('馬賽克').first);
    await _settle(t);
    await t.tap(find.byTooltip('加一塊馬賽克'));
    await _settle(t);
    await t.tap(find.byTooltip('調整樣式'));
    await _settle(t);
    expect(find.text('馬賽克樣式'), findsOneWidget);
    final m = _live(t).mosaics.single;
    expect(m.style.type, 0);

    await t.tap(find.text('模糊'));
    await _settle(t, 2);
    expect(m.style.type, 1);
    await t.tap(find.text('純色'));
    await _settle(t, 2);
    expect(m.style.type, 2);

    // 關掉樣式表再按上一步
    await t.tapAt(const Offset(600, 100));
    await _settle(t);
    await t.tap(find.byTooltip('上一步'));
    await _settle(t);
    expect(_live(t).mosaics.single.style.type, 1, reason: '只退「純色」那一步');
    await t.tap(find.byTooltip('上一步'));
    await _settle(t);
    expect(_live(t).mosaics.single.style.type, 0, reason: '再退「模糊」那一步');
    expect(_live(t).mosaics.length, 1, reason: '加馬賽克那一步還沒退');
    await _drainHint(t);
    expect(t.takeException(), isNull);
  });
}
