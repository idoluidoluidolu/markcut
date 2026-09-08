// 成品不能比預覽糊：來源太小就先放大到長邊 kPhotoExportMinLong 再合成。
//
// 實測回報「圖片編輯匯出的照片畫質跟預覽差很多」：那張的來源是 App
// 自己做的 GIF（長邊 480），成品照來源尺寸出＝400×480，浮水印的字在
// 那麼小的畫布上只剩幾十個像素；預覽卻是小圖拉滿版＋向量畫字。
// 這裡釘住：小圖放大到 1440、大圖一顆像素都不動、minLongSide: 0 可關
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/watermark_renderer.dart';

Future<ui.Image> _solid(int w, int h, [Color c = const Color(0xFF808080)]) {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = c,
  );
  return rec.endRecording().toImage(w, h);
}

/// 沒有任何浮水印：只看尺寸
WatermarkSettings _noMarks() => WatermarkSettings(
  text: TextMark(enabled: false),
  logo: LogoMark(enabled: false),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('400×480 的來源：成品放大到長邊 1440，比例不變', () async {
    final src = await _solid(400, 480);
    final out = await WatermarkRenderer.compositePhoto(src, _noMarks());
    expect(out.height, kPhotoExportMinLong);
    expect(out.width, 1200);
    out.dispose();
    src.dispose();
  });

  test('橫的小圖也是長邊對齊 1440', () async {
    final src = await _solid(640, 360);
    final out = await WatermarkRenderer.compositePhoto(src, _noMarks());
    expect(out.width, kPhotoExportMinLong);
    expect(out.height, 810);
    out.dispose();
    src.dispose();
  });

  test('夠大的來源照原尺寸出：一顆像素都不縮也不放', () async {
    final src = await _solid(3000, 2000);
    final out = await WatermarkRenderer.compositePhoto(src, _noMarks());
    expect(out.width, 3000);
    expect(out.height, 2000);
    out.dispose();
    src.dispose();
  });

  test('剛好 1440 不動；1439 才放大', () async {
    final exact = await _solid(1440, 900);
    final o1 = await WatermarkRenderer.compositePhoto(exact, _noMarks());
    expect((o1.width, o1.height), (1440, 900));
    final under = await _solid(1439, 900);
    final o2 = await WatermarkRenderer.compositePhoto(under, _noMarks());
    expect(o2.width, 1440);
    o1.dispose();
    o2.dispose();
    exact.dispose();
    under.dispose();
  });

  test('minLongSide: 0 ＝關掉放大（照來源尺寸）', () async {
    final src = await _solid(400, 480);
    final out = await WatermarkRenderer.compositePhoto(
      src,
      _noMarks(),
      minLongSide: 0,
    );
    expect((out.width, out.height), (400, 480));
    out.dispose();
    src.dispose();
  });

  test('換畫布比例：先放大再貼黑底，畫布跟著是 1440 級', () async {
    // 400×480 → 放大到 1200×1440 → 1:1 畫布＝1440×1440，照片置中、
    // 左右各 120 黑邊
    final src = await _solid(400, 480, const Color(0xFFFFFFFF));
    final out = await WatermarkRenderer.compositePhoto(
      src,
      _noMarks(),
      canvasAspect: 1.0,
    );
    expect((out.width, out.height), (1440, 1440));
    final raw = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    int r(int x, int y) => raw.getUint8((y * out.width + x) * 4);
    expect(r(10, 720), 0, reason: '左邊黑邊');
    expect(r(1430, 720), 0, reason: '右邊黑邊');
    expect(r(720, 720), 255, reason: '中間是照片');
    out.dispose();
    src.dispose();
  });

  test('放大用的是內容本身（不是塞黑邊）：整張仍是原色', () async {
    final src = await _solid(300, 200, const Color(0xFF3060C0));
    final out = await WatermarkRenderer.compositePhoto(src, _noMarks());
    final raw = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    for (final (x, y) in [
      (0, 0),
      (out.width - 1, out.height - 1),
      (700, 400),
    ]) {
      final i = (y * out.width + x) * 4;
      expect(
        (raw.getUint8(i), raw.getUint8(i + 1), raw.getUint8(i + 2)),
        (0x30, 0x60, 0xC0),
        reason: '($x,$y)',
      );
    }
    out.dispose();
    src.dispose();
  });
}
