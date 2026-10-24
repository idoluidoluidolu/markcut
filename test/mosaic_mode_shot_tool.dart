// 馬賽克模式截圖工具（不是回歸測試）。
//
// 用真的佈景、真的字體（NotoSansTC＋Material Icons）、iPhone 14 視窗
//（390×844、DPR 3、安全區 47/34），把首頁＋選單、照片馬賽克模式
//（自動找到三張臉、點掉一張、換成模糊）拍成 PNG，給設計檢視用：
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/mosaic_mode_shot_tool.dart
//
// 照片是自己畫的（三個人），找臉的通道回這三顆頭的位置。
// 沒設環境變數時整支略過。檔名沒有 _test 結尾，整批 flutter test 也不會撿它。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/home_screen.dart';
import 'package:markcut/screens/photo_editor_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/watermark_layer.dart';

final _shotKey = GlobalKey();

String? _materialIconsPath() {
  final candidates = <String>[];
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    candidates.add(
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  final exe = Platform.resolvedExecutable.replaceAll(
    String.fromCharCode(92),
    '/',
  );
  final i = exe.indexOf('/bin/cache/');
  if (i >= 0) {
    candidates.add(
      '${exe.substring(0, i)}'
      '/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

/// 三個人：頭的中心與半徑（照片像素）
const _heads = [
  (x: 300.0, y: 380.0, r: 80.0, skin: 0xFFE0B08A, hair: 0xFF2E2420, shirt: 0xFFE66F51),
  (x: 600.0, y: 350.0, r: 90.0, skin: 0xFFC98F67, hair: 0xFF4A3426, shirt: 0xFF3E6FA8),
  (x: 900.0, y: 390.0, r: 75.0, skin: 0xFFEDC39E, hair: 0xFF1F1A17, shirt: 0xFF4E9A7A),
];
const _w = 1200.0, _h = 900.0;

Future<Uint8List> _scene() async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(
    const Rect.fromLTWH(0, 0, _w, _h * 0.55),
    Paint()..color = const Color(0xFFA9C9DA),
  );
  c.drawRect(
    const Rect.fromLTWH(0, _h * 0.55, _w, _h * 0.45),
    Paint()..color = const Color(0xFFD2C29F),
  );
  c.drawOval(
    const Rect.fromLTWH(-80, 380, 520, 160),
    Paint()..color = const Color(0xFF8DB38A),
  );
  for (final p in _heads) {
    final r = p.r;
    c.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(p.x - 1.7 * r, p.y + 0.85 * r, 3.4 * r, _h),
        topLeft: Radius.circular(r * 1.1),
        topRight: Radius.circular(r * 1.1),
      ),
      Paint()..color = Color(p.shirt),
    );
    c.drawCircle(Offset(p.x, p.y), r, Paint()..color = Color(p.skin));
    c.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(p.x - 1.05 * r, p.y - 1.1 * r, 2.1 * r, 1.05 * r),
        topLeft: Radius.circular(r * 1.05),
        topRight: Radius.circular(r * 1.05),
        bottomLeft: Radius.circular(r * 0.25),
        bottomRight: Radius.circular(r * 0.25),
      ),
      Paint()..color = Color(p.hair),
    );
    for (final dx in const [-0.36, 0.36]) {
      c.drawCircle(
        Offset(p.x + dx * r, p.y + 0.12 * r),
        r * 0.08,
        Paint()..color = const Color(0xFF2A211C),
      );
    }
  }
  final img = await rec.endRecording().toImage(_w.toInt(), _h.toInt());
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '截圖工具，要給輸出資料夾才會跑');
    return;
  }

  late String photoPath;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Directory(out).createSync(recursive: true);
    for (final path in const [
      'assets/fonts/NotoSansTC.ttf',
      'assets/fonts/NotoSansTC-Bold.ttf',
    ]) {
      final loader = FontLoader('NotoSansTC')
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
    final icons = _materialIconsPath();
    expect(icons, isNotNull, reason: '找不到 materialicons-regular.otf');
    final il = FontLoader('MaterialIcons')
      ..addFont(File(icons!).readAsBytes().then((b) => b.buffer.asByteData()));
    await il.load();
    photoPath = '$out${Platform.pathSeparator}mz_scene.png';
    File(photoPath).writeAsBytesSync(await _scene());
    // 找臉：回三顆頭的「眉毛到下巴」那一塊（偵測器回的大概就是這個範圍）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('markcut/face'), (
          _,
        ) async {
          return [
            for (final p in _heads)
              {
                'x': (p.x - 0.8 * p.r) / _w,
                'y': (p.y - 0.6 * p.r) / _h,
                'w': 1.6 * p.r / _w,
                'h': 1.5 * p.r / _h,
              },
          ];
        });
  });

  void phone(WidgetTester t) {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);
  }

  Future<void> settle(WidgetTester t, [int n = 15]) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> snap(WidgetTester t, String name) async {
    await t.runAsync(() async {
      final b =
          _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await b.toImage(pixelRatio: 3);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      im.dispose();
      File(
        '$out${Platform.pathSeparator}$name',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('首頁＋選單 → mz_home_menu.png', (t) async {
    SharedPreferences.setMockInitialValues({kHomeProfileHintKey: true});
    phone(t);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: const LightPage(child: HomeScreen()),
        ),
      ),
    );
    await settle(t);
    await t.tap(find.byType(FloatingActionButton));
    await settle(t);
    await snap(t, 'mz_home_menu.png');
  });

  testWidgets('馬賽克模式：找到三張臉 → 點掉一張 → 換模糊', (t) async {
    SharedPreferences.setMockInitialValues({});
    phone(t);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: PhotoEditorScreen(
            photo: XFile(photoPath, name: 'mz_scene.png'),
            mosaicMode: true,
          ),
        ),
      ),
    );
    await settle(t, 25);
    await snap(t, 'mz_photo.png');

    // 點中間那個人的臉
    final canvas = t.getRect(find.byType(WatermarkLayer).first);
    final m = t
        .widget<WatermarkLayer>(find.byType(WatermarkLayer).first)
        .settings
        .mosaics[1];
    await t.tapAt(
      Offset(
        canvas.left + m.x * canvas.width,
        canvas.top + m.y * canvas.height,
      ),
    );
    await settle(t, 6);
    await snap(t, 'mz_photo_off.png');

    await t.tap(find.text('模糊'));
    await settle(t, 6);
    await snap(t, 'mz_photo_blur.png');
    await t.pump(const Duration(seconds: 4));
  });
}
