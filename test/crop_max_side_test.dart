// 裁切頁出檔的長邊上限（cropImage 的 maxSide）：
//
// 浮水印 Logo 本來就要縮到 4096，以前是裁切頁先編一張全尺寸 PNG、
// 面板再解開重縮再編一次——12MP 的圖多花一兩秒，而且整段沒畫面回饋
//（實測回報「按確認後什麼都沒發生，然後圖片才跳出來」）。現在
// CropScreen 出檔就夾；沒給 maxSide 的（拼圖、影片素材）維持原尺寸。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/crop_screen.dart';

Future<Uint8List> _png(int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF3060A0),
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

Future<(int, int)> _size(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final s = (frame.image.width, frame.image.height);
  frame.image.dispose();
  codec.dispose();
  return s;
}

Future<void> _wait(WidgetTester t, [int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump(const Duration(milliseconds: 60));
  }
}

/// 從一顆按鈕進裁切頁、直接按完成，回傳裁出來的 bytes
Future<Uint8List?> _cropWhole(
  WidgetTester t,
  Uint8List src, {
  int? maxSide,
}) async {
  Uint8List? out;
  var done = false;
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async {
            out = await cropImage(ctx, src, maxSide: maxSide);
            done = true;
          },
          child: const Text('go'),
        ),
      ),
    ),
  );
  await t.tap(find.text('go'));
  await _wait(t); // 裁切頁解圖
  expect(find.text('完成'), findsOneWidget);
  await t.tap(find.text('完成'));
  await _wait(t, 12); // 出檔（toImage → PNG）
  expect(done, isTrue, reason: '裁切頁要把結果 pop 回來');
  return out;
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(800, 1200);
    v.devicePixelRatio = 1.0;
  });

  testWidgets('maxSide：裁出來的長邊夾到上限、比例不變', (t) async {
    final src = (await t.runAsync(() => _png(600, 300)))!;
    final out = await _cropWhole(t, src, maxSide: 200);
    expect(out, isNotNull);
    final (w, h) = (await t.runAsync(() => _size(out!)))!;
    expect(w, 200);
    expect(h, 100);
  });

  testWidgets('沒給 maxSide：照裁切框原尺寸出（拼圖、影片素材的路徑不變）', (t) async {
    final src = (await t.runAsync(() => _png(600, 300)))!;
    final out = await _cropWhole(t, src);
    expect(out, isNotNull);
    final (w, h) = (await t.runAsync(() => _size(out!)))!;
    expect(w, 600);
    expect(h, 300);
  });

  testWidgets('maxSide 比圖大：不放大', (t) async {
    final src = (await t.runAsync(() => _png(120, 80)))!;
    final out = await _cropWhole(t, src, maxSide: 4096);
    expect(out, isNotNull);
    final (w, h) = (await t.runAsync(() => _size(out!)))!;
    expect(w, 120);
    expect(h, 80);
  });
}
