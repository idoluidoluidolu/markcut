// 調色（ColorGrade）跟其他東西疊在一起時，預覽跟成品要是同一回事：
// 1. 純色筆刷馬賽克：預覽以前把筆刷顏色一起調了、匯出畫的是原色
// 2. 換畫布比例的黑邊：匯出以前先貼黑底再整張調色，黑邊被亮度抬成灰
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/color_grade.dart';
import 'package:markcut/models/mosaic.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/photo_editor_screen.dart';
import 'package:markcut/services/watermark_renderer.dart';

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

/// 沒有任何浮水印（只看照片、馬賽克、調色）
WatermarkSettings _noMarks() => WatermarkSettings(
  text: TextMark(enabled: false),
  logo: LogoMark(enabled: false),
);

/// (r, g, b) at (x, y)
(int, int, int) _px(ByteData raw, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return (raw.getUint8(i), raw.getUint8(i + 1), raw.getUint8(i + 2));
}

Future<ByteData> _raw(ui.Image img) async =>
    (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 迴歸守門（稽核探針證實：preview=(255,76,76)、export=(255,0,0)）：
  // 純色筆刷在有調色時，預覽的筆刷分支不分樣式一律包 ColorFiltered，
  // 純色也被亮度抬了；匯出（paintMosaicStroke）畫的是原色、跟方形純色
  // 補丁一致。使用者挑什麼顏色就該是什麼顏色——預覽改成跟匯出一樣
  testWidgets('照片：純色筆刷馬賽克＋調色，預覽的筆刷顏色＝匯出的筆刷顏色', (t) async {
    late Uint8List photo;
    await t.runAsync(() async {
      photo = await _png(const Color(0xFF808080), 400, 400);
    });
    final stroke = PhotoMosaic(
      stroke: [0.2, 0.5, 0.8, 0.5],
      brush: 0.2,
      style: MosaicStyle(type: 2, color: 0xFFFF0000),
    );
    final grade = ColorGrade(brightness: 0.3);
    final settings = _noMarks()..mosaics.add(stroke);
    // 從草稿進來：馬賽克跟調色一起還原（不必在畫面上塗、拉滑桿）
    final draft = jsonEncode({
      ...settings.toJson(),
      'color': grade.toJson(),
      'extraWms': <Object>[],
    });

    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: PhotoEditorScreen(
          photo: XFile.fromData(photo, name: 'p.png', mimeType: 'image/png'),
          draft: draft,
        ),
      ),
    );
    await _settle(t, 20);

    // 預覽：筆刷補丁那一層（自己一個 RepaintBoundary）抓下來讀筆畫中心
    final patch = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_MosaicStrokePainter',
    );
    expect(patch, findsOneWidget, reason: '筆刷補丁要畫出來');
    final boundaryFinder = find
        .ancestor(of: patch, matching: find.byType(RepaintBoundary))
        .first;
    final boundary = t.renderObject<RenderRepaintBoundary>(boundaryFinder);
    late (int, int, int) preview;
    await t.runAsync(() async {
      final img = await boundary.toImage();
      final raw = await _raw(img);
      preview = _px(raw, img.width, img.width ~/ 2, img.height ~/ 2);
      img.dispose();
    });

    // 匯出：同一份設定合成，讀同一個位置
    late (int, int, int) export;
    await t.runAsync(() async {
      final out = await WatermarkRenderer.renderPhotoComposite(
        photo,
        _noMarks(),
        grade: grade,
        mosaics: [stroke],
      );
      final codec = await ui.instantiateImageCodec(out);
      final img = (await codec.getNextFrame()).image;
      export = _px(await _raw(img), img.width, img.width ~/ 2, img.height ~/ 2);
      img.dispose();
    });

    expect(export, (255, 0, 0), reason: '匯出畫的是挑的那個顏色');
    expect(preview, export, reason: '預覽的筆刷顏色要跟成品一樣（所見即所得）');
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  // 迴歸守門：直式照片、畫布 16:9、亮度 +30% → 匯出的左右黑邊以前是
  //(76,76,76)（先貼黑底再整張套矩陣），預覽的黑邊永遠是純黑
  test('換畫布比例＋調色：匯出的黑邊還是純黑，照片區有調到', () async {
    final photo = await _png(const Color(0xFF00FF00), 200, 400);
    final codec = await ui.instantiateImageCodec(photo);
    final src = (await codec.getNextFrame()).image;
    final out = await WatermarkRenderer.compositePhoto(
      src,
      _noMarks(),
      grade: ColorGrade(brightness: 0.3),
      canvasAspect: 16 / 9,
    );
    expect((out.width, out.height), (711, 400));
    final raw = await _raw(out);
    // 黑邊：左 5px、右 5px
    expect(_px(raw, out.width, 5, 200), (0, 0, 0), reason: '左黑邊不能被調色');
    expect(_px(raw, out.width, out.width - 5, 200), (
      0,
      0,
      0,
    ), reason: '右黑邊不能被調色');
    // 照片區（畫布正中）：綠色被亮度抬了（R、B 從 0 抬到 76）
    final mid = _px(raw, out.width, out.width ~/ 2, 200);
    expect(mid.$2, 255);
    expect(mid.$1, closeTo(76, 2), reason: '照片本身要有調到色');
    expect(mid.$3, closeTo(76, 2));
    out.dispose();
    src.dispose();
  });

  // 對照：沒換比例時調色照舊整張套（照片區的數值跟上面一樣）
  test('沒換比例：調色照舊套在整張照片上', () async {
    final photo = await _png(const Color(0xFF00FF00), 200, 400);
    final codec = await ui.instantiateImageCodec(photo);
    final src = (await codec.getNextFrame()).image;
    final out = await WatermarkRenderer.compositePhoto(
      src,
      _noMarks(),
      grade: ColorGrade(brightness: 0.3),
    );
    expect((out.width, out.height), (200, 400));
    final raw = await _raw(out);
    final c = _px(raw, out.width, 100, 200);
    expect(c.$1, closeTo(76, 2));
    expect(c.$2, 255);
    out.dispose();
    src.dispose();
  });
}
