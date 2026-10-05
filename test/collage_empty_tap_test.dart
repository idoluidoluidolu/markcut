// 拼圖自由模式：空畫布點一下＝加照片（測試員：「這邊點畫布＝加照片」）。
// 有照片之後點畫布照舊是選取／取消選取，不會再跳選取器；連點只開一個
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/collage_screen.dart';

/// 假的相簿選取器：數被叫了幾次，回 [next] 這批
class _Picker extends ImagePickerPlatform {
  List<XFile> next = const [];
  int calls = 0;

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    calls++;
    return next;
  }
}

Future<Uint8List> _png(Color c, int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = c,
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

Future<List<XFile>> _photos(WidgetTester t, int n) async {
  late List<Uint8List> bytes;
  await t.runAsync(() async {
    bytes = [
      for (var i = 0; i < n; i++)
        await _png(Color(0xFF204060 + i * 0x101010), 60, 40),
    ];
  });
  return [
    for (var i = 0; i < n; i++)
      XFile.fromData(bytes[i], name: 'p$i.png', mimeType: 'image/png'),
  ];
}

CollageLayoutPeek _peek(WidgetTester t) =>
    t.state(find.byType(CollageScreen)) as CollageLayoutPeek;

Future<void> _waitLoaded(WidgetTester t) async {
  for (
    var i = 0;
    i < 80 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    i++
  ) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump();
  }
}

Future<void> _waitItems(WidgetTester t, int want) async {
  for (var i = 0; i < 200 && _peek(t).layout.items.length < want; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump();
  }
  await t.pump(const Duration(milliseconds: 100));
}

/// 空手進拼圖頁、切到自由模式（假選取器裝好）
Future<_Picker> _openFree(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  final picker = _Picker();
  final prev = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = picker;
  addTearDown(() => ImagePickerPlatform.instance = prev);
  // 安卓的系統相片選取器（markcut/pick）：回 null＝這台沒有，退到
  // image_picker（跟 collage_free_cap_test 同一套）
  final b = TestDefaultBinaryMessengerBinding.instance;
  b.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('markcut/pick'),
    (_) async => null,
  );
  addTearDown(
    () => b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/pick'),
      null,
    ),
  );
  await t.pumpWidget(const MaterialApp(home: CollageScreen()));
  await _waitLoaded(t);
  await t.tap(find.text('自由'));
  await t.pumpAndSettle();
  return picker;
}

void main() {
  testWidgets('空畫布點一下就開選取器，照片排上畫布；之後點畫布是選照片、不再開選取器', (t) async {
    final picker = await _openFree(t);
    expect(_peek(t).layout.items, isEmpty);
    picker.next = await _photos(t, 3);

    // 點的是畫布本身（提示字就在畫布正中央）
    await t.tap(find.text('點一下加照片'));
    await _waitItems(t, 3);
    expect(picker.calls, 1);
    expect(_peek(t).layout.items.length, 3);
    expect(find.text('點一下加照片'), findsNothing);

    // 有照片了：點畫布＝選取，不能又跳選取器。畫布是私有的 _FreePainter，
    // 靠型別名字找（跟 collage_pinch_test 同一招）
    final paint = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString().contains('FreePainter'),
    );
    await t.tapAt(t.getCenter(paint));
    await t.pump(const Duration(milliseconds: 300));
    expect(picker.calls, 1, reason: '有照片之後點畫布不開選取器');
    expect(_peek(t).layout.items.length, 3);
    expect(t.takeException(), isNull);
  });

  testWidgets('空畫布連點兩下只開一個選取器', (t) async {
    final picker = await _openFree(t);
    picker.next = await _photos(t, 2);
    final hint = find.text('點一下加照片');
    final at = t.getCenter(hint);
    await t.tapAt(at);
    await t.tapAt(at);
    await _waitItems(t, 2);
    expect(picker.calls, 1);
    expect(_peek(t).layout.items.length, 2);
    expect(t.takeException(), isNull);
  });
}
