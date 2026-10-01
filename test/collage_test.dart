import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:markcut/screens/collage_screen.dart';

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

Future<void> _pumpFrames(WidgetTester t, [int n = 5]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

/// 開一個兩張照片的拼圖：a 是橫的紅圖（300×200）、b 是直的藍圖
///（200×300）。回傳宮格的範圍
Future<Rect> _pumpCollage(WidgetTester t) async {
  late Uint8List a;
  late Uint8List b;
  // 圖片編解碼是真非同步，要包 runAsync 才會完成
  await t.runAsync(() async {
    a = await _png(const Color(0xFFFF0000), 300, 200);
    b = await _png(const Color(0xFF0000FF), 200, 300);
  });
  await t.pumpWidget(
    MaterialApp(
      home: CollageScreen(
        photos: [
          XFile.fromData(a, name: 'a.png', mimeType: 'image/png'),
          XFile.fromData(b, name: 'b.png', mimeType: 'image/png'),
        ],
      ),
    ),
  );
  // 等 _load 讀檔＋解碼完成（輪詢直到轉圈圈消失）
  for (var i = 0;
      i < 50 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pump();
  }
  expect(find.byType(CircularProgressIndicator), findsNothing);
  return t.getRect(find.byType(AspectRatio).first);
}

/// 每一格目前放的照片寬度（照格子順序）：a 是 300、b 是 200
List<int> _cellWidths(WidgetTester t) => [
  for (final c in t.widgetList<CustomPaint>(find.byType(CustomPaint)))
    if (c.painter.runtimeType.toString() == '_CellPainter')
      ((c.painter! as dynamic).img as ui.Image).width,
];

void main() {
  testWidgets('拼圖：拖曳互換、鎖定拖曳構圖、開格線都不炸', (t) async {
    final grid = await _pumpCollage(t);
    // 點在上排格子的中心，避開畫布正中央的預設浮水印：拼圖分頁點到
    // 浮水印框內會選取並切到浮水印分頁（使用者指定），那不是這裡要測的
    final cellA = Offset(grid.left + grid.width * 0.25, grid.top + grid.height * 0.25);
    final cellB = Offset(grid.left + grid.width * 0.75, grid.top + grid.height * 0.25);

    // 沒選取：拖曳 A 到 B ＝ 互換
    await t.dragFrom(cellA, cellB - cellA);
    await _pumpFrames(t);

    // 拖到一半放格外
    await t.dragFrom(cellA, Offset(0, grid.height));
    await _pumpFrames(t);

    // 點一下鎖定，拖曳調構圖（各方向、含拖出界）
    await t.tapAt(cellA);
    await _pumpFrames(t);
    await t.dragFrom(cellA, const Offset(40, 25));
    await _pumpFrames(t);
    await t.dragFrom(cellA, const Offset(-500, -500));
    await _pumpFrames(t);

    // 解除鎖定再開格線拖曳
    await t.tapAt(cellA);
    await _pumpFrames(t);
    await t.tap(find.byType(Switch));
    await _pumpFrames(t);
    await t.dragFrom(cellB, cellA - cellB);
    await _pumpFrames(t);

    // 用加減器把格數加大（會多出空格）再把照片拖到空格。
    // 兩顆加號分別是「欄」與「列」
    final plus = find.byIcon(Icons.add);
    expect(plus, findsNWidgets(2), reason: '欄與列各一顆加號');
    await t.tap(plus.first);
    await _pumpFrames(t);
    await t.tap(plus.last);
    await _pumpFrames(t);
    final small = Offset(
      grid.left + grid.width / 6,
      grid.top + grid.height / 6,
    );
    final empty = Offset(grid.center.dx, grid.bottom - grid.height / 6);
    await t.dragFrom(small, empty - small);
    await _pumpFrames(t);

    // 一路加到上限，確認擋得住而且不會炸
    for (var i = 0; i < 10; i++) {
      await t.tap(find.byIcon(Icons.add).first, warnIfMissed: false);
      await _pumpFrames(t, 2);
      await t.tap(find.byIcon(Icons.add).last, warnIfMissed: false);
      await _pumpFrames(t, 2);
    }

    // 再減回小格數
    for (var i = 0; i < 6; i++) {
      await t.tap(find.byIcon(Icons.remove).first, warnIfMissed: false);
      await _pumpFrames(t, 2);
      await t.tap(find.byIcon(Icons.remove).last, warnIfMissed: false);
      await _pumpFrames(t, 2);
    }

    // 桌面情境：滑鼠拖曳互換
    await t.dragFrom(cellA, cellB - cellA, kind: PointerDeviceKind.mouse);
    await _pumpFrames(t);

    // 鎖定 → 滾輪放大 → 再用滑鼠拖曳構圖（桌面實際操作路徑）
    await t.tapAt(cellA);
    await _pumpFrames(t);
    final wheel = TestPointer(7, PointerDeviceKind.mouse);
    await t.sendEventToBinding(wheel.hover(cellA));
    for (var i = 0; i < 8; i++) {
      await t.sendEventToBinding(wheel.scroll(const Offset(0, -120)));
      await t.pump();
    }
    await t.dragFrom(cellA, const Offset(60, 40), kind: PointerDeviceKind.mouse);
    await _pumpFrames(t);
    await t.dragFrom(
      cellA,
      const Offset(-800, -800),
      kind: PointerDeviceKind.mouse,
    );
    await _pumpFrames(t);
    // 縮回去再拖
    for (var i = 0; i < 12; i++) {
      await t.sendEventToBinding(wheel.scroll(const Offset(0, 120)));
      await t.pump();
    }
    await t.dragFrom(cellA, const Offset(30, 30), kind: PointerDeviceKind.mouse);
    await _pumpFrames(t);

    expect(t.takeException(), isNull);
  });

  // 使用者回報：點了選取（鎖定）之後長按，拖曳換照片就不見了
  testWidgets('鎖定中的格子：按住不動再拖＝換位置，鎖定跟著照片走；'
      '一按就慢慢滑＝調構圖', (t) async {
    final grid = await _pumpCollage(t);
    final cellA = Offset(grid.left + grid.width * 0.25, grid.top + grid.height * 0.25);
    final cellB = Offset(grid.left + grid.width * 0.75, grid.top + grid.height * 0.25);
    expect(_cellWidths(t), [300, 200], reason: '起始：a 在第一格、b 在第二格');

    // 鎖定第一格：右上角出現「換照片」鈕
    await t.tapAt(cellA);
    await _pumpFrames(t);
    expect(t.getCenter(find.byIcon(Icons.cached)).dx, lessThan(grid.center.dx));

    // 一按就慢慢滑（還沒滑過拖曳門檻就超過 200ms）：這是在調構圖，
    // 不能被當成按住拿起來
    var g = await t.startGesture(cellA);
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(3, 0));
      await t.pump(const Duration(milliseconds: 50));
    }
    await g.moveBy(const Offset(30, 0));
    await t.pump();
    await g.up();
    await _pumpFrames(t);
    expect(_cellWidths(t), [300, 200], reason: '調構圖卻把照片搬走了');

    // 按住不動 300ms → 拿起來 → 拖到第二格放開＝互換
    g = await t.startGesture(cellA);
    await t.pump(const Duration(milliseconds: 300));
    for (var i = 1; i <= 6; i++) {
      await g.moveTo(Offset.lerp(cellA, cellB, i / 6)!);
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await _pumpFrames(t);
    expect(_cellWidths(t), [200, 300], reason: '鎖定中的格子按住拖曳沒有換位置');
    // 鎖定跟著那張照片到第二格
    expect(
      t.getCenter(find.byIcon(Icons.cached)).dx,
      greaterThan(grid.center.dx),
      reason: '換完位置，鎖定沒有跟著照片走',
    );
    expect(t.takeException(), isNull);
  });
}
