// 裁切畫面的快照（golden）。
//
// 這張圖同時驗三件事：圖片有解出來、按比例會變成正方形並置中、
// 拖角落會鎖著比例往內縮。裁切的數學全在 widget 裡，沒有可以單獨
// 測的純函式，快照是唯一擋得住回歸的方式。
//
// 產生／更新圖片：
//   flutter test --update-goldens test/crop_screen_golden_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/crop_screen.dart';
import 'package:markcut/theme.dart';

/// 畫一張有明顯構圖的假照片，才看得出裁切框裁到哪
Future<Uint8List> fakePhoto(int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF3A5A8C),
  );
  canvas.drawCircle(
    Offset(w * 0.5, h * 0.42),
    w * 0.22,
    Paint()..color = const Color(0xFFE8C36B),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, h * 0.72, w.toDouble(), h * 0.28),
    Paint()..color = const Color(0xFF2E6B4F),
  );
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final (family, path) in const [
      ('NotoSansTC', 'assets/fonts/NotoSansTC.ttf'),
      ('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
  });

  testWidgets('裁切畫面', (tester) async {
    // toImage / instantiateImageCodec 是真的非同步工作，
    // widget test 一律要包 runAsync，不然直接卡住不回來
    final bytes = (await tester.runAsync(() => fakePhoto(900, 1200)))!;
    await tester.binding.setSurfaceSize(const Size(390, 780));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: CropScreen(bytes: bytes),
      ),
    );
    // 圖片解碼是真的非同步工作，widget test 要用 runAsync 才跑得完
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 按 1:1：框要變成正方形並置中
    await tester.tap(find.text('1:1'));
    await tester.pump(const Duration(milliseconds: 50));
    // 再拖左上角往內縮，驗手勢真的有作用（比例鎖著，另一邊要跟著算）
    // 要抓「裁切那一張 CustomPaint」——.last 會抓到比例膠囊的水波紋
    final paint = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString().contains('CropPainter'),
    );
    final area = tester.getRect(paint);
    // 框現在是置中的正方形：左上角在這裡
    final side = area.width;
    final tl = Offset(
      area.center.dx - side / 2 + 2,
      area.center.dy - side / 2 + 2,
    );
    await tester.dragFrom(tl, const Offset(70, 70));
    await tester.pump(const Duration(milliseconds: 50));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/crop_screen.png'),
    );
  });
}
