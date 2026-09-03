import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/png_size.dart';

/// 單張照片匯出 JPEG 前要把真實尺寸交給壓縮外掛（不給就被縮到 1920），
/// 尺寸從 PNG 檔頭直接讀——這裡確認讀出來的跟真的一樣
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Uint8List> png(int w, int h) async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3366CC),
    );
    final img = await rec.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return data!.buffer.asUint8List();
  }

  test('讀到的尺寸跟渲染的一樣（含非 2 的冪、非正方形）', () async {
    expect(pngSize(await png(4000, 3000)), (4000, 3000));
    expect(pngSize(await png(37, 1201)), (37, 1201));
    expect(pngSize(await png(1, 1)), (1, 1));
  });

  test('不是 PNG 回 null', () {
    expect(pngSize(Uint8List(0)), isNull);
    expect(pngSize(Uint8List(10)), isNull);
    // JPEG 簽名
    final j = Uint8List(64)..[0] = 0xFF..[1] = 0xD8..[2] = 0xFF;
    expect(pngSize(j), isNull);
    // 簽名對但第一個 chunk 不是 IHDR
    final bad = Uint8List(64);
    bad.setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(pngSize(bad), isNull);
  });
}
