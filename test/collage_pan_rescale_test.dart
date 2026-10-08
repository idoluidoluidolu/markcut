// 拼圖格子的平移量是「預覽圖的像素」單位：預覽圖因為照片變多而換成小一級
// 的時候、或是從舊版（一律 1600 預覽）的草稿讀回來的時候，平移量都要跟著
// 等比例換算，取景框才會停在同一個地方。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/collage_screen.dart';

/// 假的相簿選取器：「加入照片」拿到的就是 [next] 這批
class _Picker extends ImagePickerPlatform {
  List<XFile> next = const [];

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => next;
}

/// [n] 張 2000×1000 的照片檔（長邊超過 1600，預覽一定會縮）
Future<List<String>> _files(WidgetTester t, Directory dir, int n) async {
  late Uint8List png;
  await t.runAsync(() async {
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      const Rect.fromLTWH(0, 0, 2000, 1000),
      Paint()..color = const Color(0xFF3060A0),
    );
    final picture = rec.endRecording();
    final img = await picture.toImage(2000, 1000);
    picture.dispose();
    png = (await img.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    img.dispose();
  });
  return [
    for (var i = 0; i < n; i++)
      (File(
        '${dir.path}${Platform.pathSeparator}p$i.png',
      )..writeAsBytesSync(png)).path,
  ];
}

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('collage_pan_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  return dir;
}

CollageLayoutPeek _peek(WidgetTester t) =>
    t.state(find.byType(CollageScreen)) as CollageLayoutPeek;

Future<void> _waitFor(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump();
  }
  expect(done(), isTrue);
}

int _loaded(WidgetTester t) => _peek(t).images.whereType<ui.Image>().length;

Map<String, dynamic> _draft(
  List<String> photos,
  List<int> order,
  Map<String, dynamic> fit0, {
  bool normalized = false,
}) =>
    jsonDecode(
          jsonEncode({
            'photos': photos,
            'order': order,
            'cols': 4,
            'rows': 2,
            'free': false,
            'aspect': 1.0,
            if (normalized) 'panNormalized': true,
            'fits': [fit0],
          }),
        )
        as Map<String, dynamic>;

void main() {
  testWidgets('舊草稿（平移量是 1600 預覽的像素）讀回來換成新預覽的單位', (t) async {
    SharedPreferences.setMockInitialValues({});
    final paths = await _files(t, _tempDir(), 8);
    await t.pumpWidget(
      MaterialApp(
        home: CollageScreen(
          restore: _draft(
            paths,
            [for (var i = 0; i < 8; i++) i],
            {'z': 2.0, 'x': 100.0, 'y': 50.0},
          ),
        ),
      ),
    );
    await _waitFor(t, () => _loaded(t) == 8);
    final img = _peek(t).images.first!;
    // 8 張＝1280 那一級；舊版這張的預覽是 1600×800
    expect([img.width, img.height], [1280, 640]);
    final fit = _peek(t).layout.fits.first;
    expect(fit.zoom, 2.0);
    expect(fit.panX, closeTo(100 * 1280 / 1600, 1e-9));
    expect(fit.panY, closeTo(50 * 640 / 800, 1e-9));
    await t.pumpWidget(const SizedBox());
    expect(t.takeException(), isNull);
  });

  testWidgets('加照片跨到下一級：畫布上的照片重解成小一級，平移量等比縮、取景不動', (t) async {
    SharedPreferences.setMockInitialValues({});
    final picker = _Picker();
    final prev = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = picker;
    addTearDown(() => ImagePickerPlatform.instance = prev);
    // 安卓的系統相片選取器回 null＝這台沒有，退到 image_picker
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
    final paths = await _files(t, _tempDir(), 7);
    // 新格式：平移量存比例（0.1 × 寬、0.05 × 高）
    await t.pumpWidget(
      MaterialApp(
        home: CollageScreen(
          restore: _draft(
            paths.take(6).toList(),
            [0, 1, 2, 3, 4, 5, -1, -1],
            {'z': 2.0, 'x': 0.1, 'y': 0.05},
            normalized: true,
          ),
        ),
      ),
    );
    await _waitFor(t, () => _loaded(t) == 6);
    final before = _peek(t).images.first!;
    expect([before.width, before.height], [1600, 800]);
    expect(_peek(t).layout.fits.first.panX, closeTo(160, 1e-9));
    expect(_peek(t).layout.fits.first.panY, closeTo(40, 1e-9));

    picker.next = [XFile(paths[6])];
    await t.tap(find.text('加入照片'));
    await _waitFor(
      t,
      () => _loaded(t) == 7 && _peek(t).images.first!.width == 1280,
    );
    final after = _peek(t).images.first!;
    expect([after.width, after.height], [1280, 640]);
    expect(before.debugDisposed, isTrue, reason: '換下來的大圖要放掉');
    final fit = _peek(t).layout.fits.first;
    expect(fit.panX / after.width, closeTo(0.1, 1e-9));
    expect(fit.panY / after.height, closeTo(0.05, 1e-9));
    // 7 張全部是 1280 那一級
    for (final img in _peek(t).images.whereType<ui.Image>()) {
      expect(img.width, 1280);
    }
    await t.pumpWidget(const SizedBox());
    expect(t.takeException(), isNull);
  });
}
