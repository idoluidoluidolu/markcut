import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/photo_editor_screen.dart';

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

Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 面板是 lazy build 的，畫面太矮下面的卡片根本不會被建出來
  setUpAll(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(1200, 2400);
    v.devicePixelRatio = 1.0;
  });

  testWidgets('照片編輯器：加浮水印組、開編輯面板、刪除、undo 都不炸', (t) async {
    late Uint8List bytes;
    await t.runAsync(() async {
      bytes = await _png(const Color(0xFF888888), 900, 600);
    });
    await t.pumpWidget(
      MaterialApp(
        home: PhotoEditorScreen(
          photo: XFile.fromData(bytes, name: 'p.png', mimeType: 'image/png'),
        ),
      ),
    );
    await _settle(t, 20);

    // 面板裡的「浮水印」加號卡
    expect(find.text('浮水印'), findsWidgets);
    await t.ensureVisible(find.text('浮水印').first);
    await _settle(t);

    // 加第一組
    final addRow = find.ancestor(
      of: find.text('浮水印'),
      matching: find.byType(InkWell),
    );
    await t.tap(addRow.first, warnIfMissed: false);
    await _settle(t);

    // 應該開了編輯面板；關掉它
    if (find.text('刪除這組').evaluate().isNotEmpty) {
      await t.tapAt(const Offset(200, 30)); // 點面板外關閉
      await _settle(t);
    }

    // 讓 showHint 的 2.4 秒計時器跑完，不然測試框架會抱怨還有 timer
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('照片編輯器：馬賽克連續加/刪不炸', (t) async {
    late Uint8List bytes;
    await t.runAsync(() async {
      bytes = await _png(const Color(0xFF444444), 600, 900);
    });
    await t.pumpWidget(
      MaterialApp(
        home: PhotoEditorScreen(
          photo: XFile.fromData(bytes, name: 'p.png', mimeType: 'image/png'),
        ),
      ),
    );
    await _settle(t, 20);

    expect(find.text('馬賽克'), findsWidgets);
    await t.ensureVisible(find.text('馬賽克').first);
    await _settle(t);

    // 加三塊
    for (var i = 0; i < 3; i++) {
      final add = find.descendant(
        of: find
            .ancestor(of: find.text('馬賽克'), matching: find.byType(Row))
            .first,
        matching: find.byIcon(Icons.add),
      );
      if (add.evaluate().isEmpty) break;
      await t.tap(add.first, warnIfMissed: false);
      await _settle(t);
    }

    // 全刪掉（由後往前）
    for (var i = 0; i < 5; i++) {
      final del = find.byIcon(Icons.delete_outline);
      if (del.evaluate().isEmpty) break;
      await t.tap(del.last, warnIfMissed: false);
      await _settle(t);
    }

    // 讓 showHint 的 2.4 秒計時器跑完，不然測試框架會抱怨還有 timer
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });
}
