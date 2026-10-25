// 一般照片編輯器（浮水印）的「馬賽克」卡：10-25 換成跟馬賽克模式同一套
//（使用者：照片上浮水印那裡的馬賽克還是舊版，要改成新版、會偵測人臉）。
//
// 守的是：
//   1. 卡片內容換成新版：縮圖排＋虛線加號、像素化／模糊、大小／濃度；
//      舊版的「加一塊」、一塊一列、單塊樣式表都沒有；一進來不自動找臉
//   2. 自動碼人臉：每張臉一塊圓圈、照片上不畫框，點臉＝碼／不碼
//   3. 畫布比例：換了比例碼好的臉跟著照片走；換了比例再找臉框也對得上
//   4. 長按照片上的一塊＝刪除；長按浮水印文字不跳選單
//   5. 兩指捏：捏在馬賽克上只動它；選著文字時捏的是文字
//   6. 筆刷畫完按完成，浮水印照樣拖得動（不留隱形選取）；筆刷沒有純色
//   7. 範本帶進來的方形照舊是方的（改成圓的會少蓋四個角），面板樣式對上它
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/mosaic.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/photo_editor_screen.dart';
import 'package:markcut/widgets/mosaic_outline.dart';
import 'package:markcut/widgets/watermark_layer.dart';

const _face = MethodChannel('markcut/face');

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

/// 照片解碼、找臉都是真的非同步，要 runAsync 才推得動
Future<void> _settle(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await t.pump(const Duration(milliseconds: 60));
  }
}

WatermarkSettings _live(WidgetTester t) =>
    t.widget<WatermarkLayer>(find.byType(WatermarkLayer).first).settings;

Rect _canvas(WidgetTester t) => t.getRect(find.byType(WatermarkLayer).first);

Offset _at(WidgetTester t, PhotoMosaic m) {
  final r = _canvas(t);
  return Offset(r.left + m.x * r.width, r.top + m.y * r.height);
}

/// 照片上畫出來的框線（縮圖那排不算）
Iterable<MosaicOutlinePainter> _outlines(WidgetTester t) {
  final canvas = _canvas(t);
  return t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .where((w) {
        final p = w.painter ?? w.foregroundPainter;
        if (p is! MosaicOutlinePainter) return false;
        return canvas.overlaps(t.getRect(find.byWidget(w)));
      })
      .map((w) => (w.painter ?? w.foregroundPainter)! as MosaicOutlinePainter);
}

Finder _sem(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);

/// 上方導覽列切到「馬賽克」
Future<void> _toCard(WidgetTester t) async {
  await t.tap(find.text('馬賽克').first);
  await _settle(t, 6);
}

/// 縮圖那排最後的虛線加號 → 選單的某一項
Future<void> _add(WidgetTester t, String item) async {
  await t.tap(_sem('新增馬賽克'));
  await _settle(t, 6);
  await t.tap(find.text(item));
  await _settle(t, 6);
}

/// 畫面比例換成 [label]
Future<void> _ratio(WidgetTester t, String label) async {
  await t.tap(find.text('原始'));
  await _settle(t, 6);
  await t.tap(find.text(label));
  await _settle(t, 8);
}

/// 兩指從 [c] 往左右各拉開
Future<void> _pinchOut(WidgetTester t, Offset c) async {
  final g1 = await t.startGesture(c - const Offset(15, 0), pointer: 7);
  await t.pump();
  final g2 = await t.startGesture(c + const Offset(15, 0), pointer: 8);
  await t.pump();
  for (var i = 1; i <= 6; i++) {
    await g1.moveTo(c - Offset(15.0 + i * 6, 0));
    await g2.moveTo(c + Offset(15.0 + i * 6, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g1.up();
  await g2.up();
  await _settle(t, 4);
}

late Directory _dir;
late String _photoPath;
int _faceCalls = 0;

Future<void> _open(WidgetTester t, {WatermarkSettings? wm}) async {
  t.view.physicalSize = const Size(900, 1800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: PhotoEditorScreen(
        photo: XFile(_photoPath, name: 'p.png', mimeType: 'image/png'),
        initialWatermark: wm,
      ),
    ),
  );
  await _settle(t, 14);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _dir = Directory.systemTemp.createTempSync('markcut_mzpanel_');
    _photoPath = '${_dir.path}${Platform.pathSeparator}p.png';
    final bytes = await _png(const Color(0xFF808080), 1000, 800);
    File(_photoPath).writeAsBytesSync(bytes);
  });

  tearDownAll(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _faceCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_face, (call) async {
          _faceCalls++;
          return [
            {'x': 0.2, 'y': 0.3, 'w': 0.15, 'h': 0.2},
            {'x': 0.6, 'y': 0.3, 'w': 0.15, 'h': 0.2},
          ];
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_face, null);
  });

  testWidgets('卡片換成新版：縮圖排＋虛線加號、效果、大小／濃度；舊版的都沒有；不自動找臉', (t) async {
    await _open(t);
    expect(_faceCalls, 0, reason: '浮水印編輯不該一進來就自動碼臉');
    await _toCard(t);
    expect(_sem('新增馬賽克'), findsOneWidget);
    expect(find.text('像素化'), findsOneWidget);
    expect(find.text('模糊'), findsOneWidget);
    expect(find.text('大小'), findsWidgets);
    expect(find.text('濃度'), findsOneWidget);
    expect(find.byTooltip('加一塊馬賽克'), findsNothing);
    expect(find.byTooltip('調整樣式'), findsNothing);
    expect(find.textContaining('第 1 塊'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('自動碼人臉：每張臉一塊圓圈、照片上不畫框；點臉＝碼↔不碼', (t) async {
    await _open(t);
    await _toCard(t);
    await _add(t, '自動碼人臉');
    expect(_faceCalls, 1);
    final ms = _live(t).mosaics;
    expect(ms.length, 2);
    expect(ms.every((m) => m.face && m.oval), isTrue);
    expect(_sem('臉'), findsNWidgets(2), reason: '縮圖那排一張臉一格');
    expect(_outlines(t), isEmpty, reason: '照片上不畫框（使用者：馬賽克不要有邊框）');

    await t.tapAt(_at(t, ms.first));
    await _settle(t, 4);
    expect(ms.first.off, isTrue, reason: '點臉要切成不碼');
    expect(_outlines(t), isEmpty, reason: '點掉的臉也不留框');
    await t.tapAt(_at(t, ms.first));
    await _settle(t, 4);
    expect(ms.first.off, isFalse, reason: '再點一下要碼回來');
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('換畫布比例：碼好的臉跟著照片走；上一步退得回來', (t) async {
    await _open(t);
    await _toCard(t);
    await _add(t, '自動碼人臉');
    final m0 = _live(t).mosaics.first;
    final (x0, y0, s0) = (m0.x, m0.y, m0.scale);

    // 1000×800 → 1:1：畫布 1000×1000，照片上下各 100 的黑邊
    await _ratio(t, '1:1');
    final m = _live(t).mosaics.first;
    expect(m.x, closeTo(x0, 1e-9), reason: '左右沒有黑邊，x 不變');
    expect(m.y, closeTo((y0 * 800 + 100) / 1000, 1e-9), reason: '要跟著照片往下挪');
    expect(
      m.scale,
      closeTo(s0 * 800 / 1000, 1e-9),
      reason: '畫布短邊變長，同樣的像素大小比例變小',
    );

    await t.tap(find.byTooltip('上一步'));
    await _settle(t, 6);
    final back = _live(t).mosaics.first;
    expect((back.x, back.y, back.scale), (x0, y0, s0));
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('換了比例再找臉：照片座標換到畫布上（照片置中、上下黑邊）', (t) async {
    await _open(t);
    await _ratio(t, '1:1');
    await _toCard(t);
    await _add(t, '自動碼人臉');
    final m = _live(t).mosaics.first;
    // 臉框 (0.2, 0.3, 0.15, 0.2)：中心往上挪框高的 8%，寬放大 1.3 倍
    expect(m.x, closeTo(0.2 + 0.075, 1e-9));
    expect(m.y, closeTo((100 + (0.3 + 0.1 - 0.016) * 800) / 1000, 1e-9));
    expect(m.scale, closeTo(0.15 * 1000 * 1.3 / 1000, 1e-9));
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('長按照片上的一塊＝刪除；長按浮水印文字不跳選單', (t) async {
    await _open(t);
    await _toCard(t);
    await _add(t, '圓圈');
    final m = _live(t).mosaics.single;
    await t.longPressAt(_at(t, m));
    await _settle(t, 6);
    expect(find.text('刪除'), findsOneWidget);
    await t.tap(find.text('刪除'));
    await _settle(t, 6);
    expect(_live(t).mosaics, isEmpty);

    await t.longPressAt(_canvas(t).center);
    await _settle(t, 6);
    expect(find.text('刪除'), findsNothing, reason: '長按的是文字，不是馬賽克');
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('兩指捏：捏在馬賽克上只動它；選著文字時捏的是文字', (t) async {
    await _open(t);
    await _toCard(t);
    await _add(t, '圓圈');
    final m = _live(t).mosaics.single;
    final s0 = m.scale;
    final text0 = _live(t).text.sizeFrac;
    await _pinchOut(t, _at(t, m));
    expect(m.scale, greaterThan(s0 * 1.5), reason: '捏的那塊要變大');
    expect(_live(t).text.sizeFrac, closeTo(text0, 1e-9), reason: '文字不該跟著變');

    // 選文字（有琥珀框）之後，捏在馬賽克上動的是文字
    await t.tapAt(_canvas(t).center);
    await _settle(t, 4);
    final s1 = m.scale;
    await _pinchOut(t, _at(t, m));
    expect(
      _live(t).text.sizeFrac,
      greaterThan(text0 * 1.5),
      reason: '選著文字就捏文字',
    );
    expect(m.scale, closeTo(s1, 1e-9));
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('筆刷畫完按完成：浮水印照樣拖得動；筆刷沒有純色', (t) async {
    await _open(t);
    await _toCard(t);
    await _add(t, '筆刷');
    expect(find.text('純色'), findsNothing, reason: '新版拿掉了純色');
    expect(find.text('純色遮蓋'), findsNothing);
    final screen = t.view.physicalSize / t.view.devicePixelRatio;
    await t.dragFrom(
      Offset(screen.width * 0.3, screen.height * 0.45),
      const Offset(150, 0),
    );
    await _settle(t, 4);
    expect(_live(t).mosaics.single.isStroke, isTrue);
    await t.tap(find.text('完成'));
    await _settle(t, 6);

    // 剛畫的那一筆以前會留著選取：浮水印從此拖不動
    final r = _canvas(t);
    await t.dragFrom(r.center, const Offset(80, 60));
    await _settle(t, 4);
    expect(_live(t).text.x, greaterThan(0.55), reason: '畫完筆刷，文字要拖得動');
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  testWidgets('範本帶進來的方形照舊是方的；面板的效果對上它', (t) async {
    final wm = WatermarkSettings();
    wm.mosaics.add(
      PhotoMosaic(x: 0.3, y: 0.3, scale: 0.3, style: MosaicStyle(type: 1)),
    );
    await _open(t, wm: wm);
    await _toCard(t);
    expect(_live(t).mosaics.single.oval, isFalse, reason: '改成圓的會少蓋四個角');
    expect(find.text('柔邊'), findsOneWidget, reason: '面板要對上模糊（模糊才有柔邊）');
    // 換效果＝每一塊一起換
    await t.tap(find.text('像素化'));
    await _settle(t, 4);
    expect(_live(t).mosaics.single.style.type, 0);
    expect(_live(t).mosaics.single.oval, isFalse);
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });
}
