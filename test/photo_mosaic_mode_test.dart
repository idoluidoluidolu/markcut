// 首頁「馬賽克」→ 照片編輯器的馬賽克模式（使用者在畫布選的「甲」）。
//
// 守的是：
//   1. PhotoMosaic 新欄位（橢圓、高寬比、臉、點掉）存得進去讀得回來，
//      舊版 JSON 照舊（沒有新欄位＝方形、不是臉）
//   2. 偵測框 → 蓋臉的橢圓：往外放一圈、往上挪，比例換算對
//   3. 成品：橢圓只碼橢圓裡面（外框四角是原圖）、點掉的臉不畫
//   4. 畫面：一進來自動找臉、全部碼上；點臉＝切換碼／不碼（不是選取）；
//      下面那排改樣式／形狀＝每一塊一起改；方框照選的形狀加；
//      沒有範本、浮水印區段、存成範本
//   5. 找不到（通道回 null）不炸、不加東西
//   6. 草稿從馬賽克模式存的：開回馬賽克模式、不再自動找一次
//   7. 10-25 改版（畫布甲＋新增一＋縮圖二＋大小甲）：照片上不畫框（點掉的臉
//      才有虛線）；「新增馬賽克」跳選單、方框放在空的地方（連加兩塊不疊）；
//      大小＝每一塊一起放大縮小；縮圖一塊一格、點臉的縮圖切換、長按刪除；
//      長按照片上的一塊也能刪；兩指捏臉只動那張臉、不會順便切成不碼；
//      拖完一塊不會留下隱形的選取
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/color_grade.dart';
import 'package:markcut/models/mosaic.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/photo_editor_screen.dart';
import 'package:markcut/services/face_detect.dart';
import 'package:markcut/services/mosaic_patch_painter.dart'
    show photoMosaicRect;
import 'package:markcut/services/watermark_renderer.dart';
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

/// 畫面上實際在用的那份設定（主浮水印圖層拿的就是那一份）
WatermarkSettings _live(WidgetTester t) =>
    t.widget<WatermarkLayer>(find.byType(WatermarkLayer).first).settings;

/// 預覽畫布（主浮水印圖層鋪滿它）
Rect _canvas(WidgetTester t) => t.getRect(find.byType(WatermarkLayer).first);

/// 一塊馬賽克的中心在畫面上的哪裡
Offset _at(WidgetTester t, PhotoMosaic m) {
  final r = _canvas(t);
  return Offset(r.left + m.x * r.width, r.top + m.y * r.height);
}

/// 照片上畫出來的框線（MosaicOutlinePainter）：縮圖那排不算
Iterable<MosaicOutlinePainter> _outlines(WidgetTester t) {
  final canvas = _canvas(t);
  return t
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .where((w) {
        final p = w.painter ?? w.foregroundPainter;
        if (p is! MosaicOutlinePainter) return false;
        // 縮圖在面板裡（畫布外面）；照片上的才算
        final box = t.getRect(find.byWidget(w));
        return canvas.overlaps(box);
      })
      .map((w) => (w.painter ?? w.foregroundPainter)! as MosaicOutlinePainter);
}

/// 按「新增馬賽克」→ 選單裡的某一項
Future<void> _add(WidgetTester t, String item) async {
  await t.tap(find.text('新增馬賽克').last);
  await _settle(t, 6);
  await t.tap(find.text(item));
  await _settle(t, 6);
}

/// 「大小」那條滑桿
Finder _sizeSlider() => find.descendant(
  of: find.ancestor(of: find.text('大小'), matching: find.byType(Row)).first,
  matching: find.byType(Slider),
);

/// 縮圖那排（Semantics 標籤：臉／沒碼的臉／方框／筆刷）
Finder _thumb(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);

late Directory _dir;
late String _photoPath;
late Uint8List _photoBytes;

/// 通道被叫了幾次、回什麼
int _faceCalls = 0;
Object? _faceReply;

Future<void> _open(WidgetTester t, {String? draft}) async {
  t.view.physicalSize = const Size(900, 1800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: PhotoEditorScreen(
        photo: XFile(_photoPath, name: 'p.png', mimeType: 'image/png'),
        mosaicMode: draft == null,
        draft: draft,
      ),
    ),
  );
  await _settle(t, 14);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _dir = Directory.systemTemp.createTempSync('markcut_mzmode_');
    _photoPath = '${_dir.path}${Platform.pathSeparator}p.png';
    _photoBytes = await _png(const Color(0xFF808080), 1000, 800);
  });

  tearDownAll(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _faceCalls = 0;
    // 兩張臉：左邊一張、右邊一張（轉正後的照片座標，0~1、左上原點）
    _faceReply = [
      {'x': 0.2, 'y': 0.3, 'w': 0.15, 'h': 0.2},
      {'x': 0.6, 'y': 0.3, 'w': 0.15, 'h': 0.2},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_face, (call) async {
          _faceCalls++;
          expect(call.method, 'detectImage');
          expect((call.arguments as Map)['path'], _photoPath);
          return _faceReply;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_face, null);
  });

  group('資料', () {
    test('新欄位存得回來；預設值不寫進 JSON；舊 JSON 照舊', () {
      final m = PhotoMosaic(aspect: 1.3, oval: true, face: true, off: true);
      final back = PhotoMosaic.fromJson(m.toJson());
      expect(back.aspect, closeTo(1.3, 1e-9));
      expect(back.oval, isTrue);
      expect(back.face, isTrue);
      expect(back.off, isTrue);
      expect(back.copy().off, isTrue, reason: 'copy 漏抄欄位');

      final plain = PhotoMosaic().toJson();
      for (final k in const ['aspect', 'oval', 'face', 'off']) {
        expect(plain.containsKey(k), isFalse, reason: '預設值不該寫「$k」');
      }
      final old = PhotoMosaic.fromJson({'x': 0.3, 'y': 0.4, 'scale': 0.5});
      expect(old.aspect, 1.0);
      expect(old.oval, isFalse);
      expect(old.face, isFalse);
      expect(old.off, isFalse);
    });

    test('偵測框 → 蓋臉的橢圓：放大一圈、往上挪、比例換算', () {
      final m = faceMosaic(
        const FaceBox(0.4, 0.3, 0.2, 0.2),
        1000,
        800,
        style: MosaicStyle(type: 1),
      );
      expect(m.face, isTrue);
      expect(m.oval, isTrue);
      expect(m.style.type, 1, reason: '樣式要照下面那排選的');
      expect(m.x, closeTo(0.5, 1e-9));
      // 中心往上挪偵測框高的 8%：額頭、頭髮邊才蓋得到
      expect(m.y, closeTo(0.3 + 0.1 - 0.016, 1e-9));
      // 寬＝框寬 ×1.3（以短邊 800 為單位）、高＝框高 ×1.45
      expect(m.scale, closeTo(0.2 * 1000 * 1.3 / 800, 1e-9));
      expect(m.aspect, closeTo((0.2 * 800 * 1.45) / (0.2 * 1000 * 1.3), 1e-9));
    });
  });

  testWidgets('成品：橢圓只碼橢圓裡面、點掉的臉不畫', (t) async {
    late Uint8List px;
    late int w;
    await t.runAsync(() async {
      final bytes = await _png(const Color(0xFFFF0000), 200, 100);
      final codec = await ui.instantiateImageCodec(bytes);
      final photo = (await codec.getNextFrame()).image;
      codec.dispose();
      final s = WatermarkSettings()..text.enabled = false;
      final out = await WatermarkRenderer.compositePhoto(
        photo,
        s,
        mosaics: [
          // 中間一顆黑色橢圓（外框 80×80：60~140、10~90）
          PhotoMosaic(
            x: 0.5,
            y: 0.5,
            scale: 0.8,
            oval: true,
            style: MosaicStyle(type: 2, color: 0xFF000000),
          ),
          // 左邊一塊點掉的臉：不該畫
          PhotoMosaic(
            x: 0.1,
            y: 0.5,
            scale: 0.3,
            face: true,
            off: true,
            style: MosaicStyle(type: 2, color: 0xFF000000),
          ),
        ],
        minLongSide: 0,
      );
      w = out.width;
      px = (await out.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      out.dispose();
      photo.dispose();
    });
    List<int> at(int x, int y) {
      final i = (y * w + x) * 4;
      return [px[i], px[i + 1], px[i + 2]];
    }

    expect(at(100, 50), [0, 0, 0], reason: '橢圓中心要碼掉');
    expect(at(62, 12), [255, 0, 0], reason: '外框角落在橢圓外面，要是原圖');
    expect(at(138, 88), [255, 0, 0], reason: '外框角落在橢圓外面，要是原圖');
    expect(at(20, 50), [255, 0, 0], reason: '點掉的臉不該畫進成品');
  });

  group('馬賽克模式', () {
    setUp(() => File(_photoPath).writeAsBytesSync(_photoBytes));

    testWidgets('一進來自動找臉、全部碼上；沒有浮水印、範本、存成範本', (t) async {
      await _open(t);
      expect(_faceCalls, 1, reason: '一進來就要找一次臉');
      final ms = _live(t).mosaics;
      expect(ms.length, 2);
      expect(ms.every((m) => m.face && m.oval && !m.off), isTrue);
      for (final x in const ['像素化', '模糊', '純色', '大小', '濃度', '新增馬賽克', '匯出']) {
        expect(find.text(x), findsWidgets, reason: '少了「$x」');
      }
      for (final x in const [
        '存成範本',
        '範本',
        '位置',
        '調色',
        '@我的浮水印',
        // 舊的三顆工具（找臉／方框／筆刷）收進「新增馬賽克」的選單
        '找臉',
        '方框',
        '筆刷',
      ]) {
        expect(find.text(x), findsNothing, reason: '馬賽克模式不該有「$x」');
      }
      expect(_thumb('臉'), findsNWidgets(2), reason: '縮圖要一塊一格');
      // 形狀是另一顆兩段切換鈕（只有圖示），不跟效果磚排成同一排選項
      expect(_thumb('圓形'), findsOneWidget);
      expect(_thumb('方形'), findsOneWidget);
      // 效果磚是白色單色圖示（同 App 其他地方），不是彩色小樣本
      for (final i in const [
        Icons.grid_on,
        Icons.blur_on,
        Icons.format_color_fill,
      ]) {
        expect(find.byIcon(i), findsOneWidget);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('點臉＝碼↔不碼（不是選取）；上一步退得回來', (t) async {
      await _open(t);
      final ms = _live(t).mosaics;
      final first = ms.first;
      await t.tapAt(_at(t, first));
      await _settle(t, 4);
      expect(first.off, isTrue, reason: '點一下要變成不碼');
      expect(ms[1].off, isFalse, reason: '另一張臉不該跟著變');
      await t.tapAt(_at(t, first));
      await _settle(t, 4);
      expect(first.off, isFalse, reason: '再點一下要碼回來');

      await t.tapAt(_at(t, first));
      await _settle(t, 4);
      expect(_live(t).mosaics.first.off, isTrue);
      await t.tap(find.byIcon(Icons.undo));
      await _settle(t, 4);
      expect(_live(t).mosaics.first.off, isFalse, reason: '上一步沒有退回來');
      expect(t.takeException(), isNull);
    });

    testWidgets('下面那排：樣式、形狀一起改每一塊；方框照選的形狀加', (t) async {
      await _open(t);
      await t.tap(find.text('純色'));
      await _settle(t, 4);
      expect(_live(t).mosaics.every((m) => m.style.type == 2), isTrue);

      await _add(t, '方框');
      final ms = _live(t).mosaics;
      expect(ms.length, 3);
      expect(ms.last.face, isFalse);
      expect(ms.last.oval, isTrue, reason: '方框要照目前選的形狀（橢圓）');
      expect(ms.last.style.type, 2, reason: '方框要照目前選的樣式');

      // 形狀切成方的：每一塊都跟著變
      await t.tap(_thumb('方形'));
      await _settle(t, 4);
      expect(_live(t).mosaics.every((m) => !m.oval), isTrue);
      expect(t.takeException(), isNull);
    });

    testWidgets('模糊才有柔邊：調了每一塊都變；換回像素化不柔、再換回模糊記得', (t) async {
      await _open(t);
      expect(find.text('柔邊'), findsNothing, reason: '像素化不該有柔邊');
      await t.tap(find.text('模糊'));
      await _settle(t, 6);
      expect(find.text('柔邊'), findsOneWidget, reason: '模糊要有柔邊（使用者問的）');
      final slider = find.descendant(
        of: find
            .ancestor(of: find.text('柔邊'), matching: find.byType(Row))
            .first,
        matching: find.byType(Slider),
      );
      await t.drag(slider, const Offset(80, 0));
      await _settle(t, 4);
      final f = _live(t).mosaics.first.style.feather;
      expect(f, greaterThan(0.2));
      expect(
        _live(t).mosaics.every((m) => (m.style.feather - f).abs() < 1e-9),
        isTrue,
        reason: '每一塊都要一起變',
      );

      await t.tap(find.text('像素化'));
      await _settle(t, 6);
      expect(find.text('柔邊'), findsNothing);
      expect(
        _live(t).mosaics.every((m) => m.style.feather == 0),
        isTrue,
        reason: '像素化不柔邊（硬邊的格子）',
      );
      await t.tap(find.text('模糊'));
      await _settle(t, 6);
      expect(
        _live(t).mosaics.first.style.feather,
        closeTo(f, 1e-9),
        reason: '換回模糊要記得剛剛的柔邊',
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('找不到（通道回 null）：不炸、不加東西', (t) async {
      _faceReply = null;
      await _open(t);
      expect(_faceCalls, 1);
      expect(_live(t).mosaics, isEmpty);
      // 提示條自己會收（計時器要走完，測試才收得乾淨）
      await t.pump(const Duration(seconds: 4));
      expect(t.takeException(), isNull);
    });

    testWidgets('同一張臉再找一次不重複加', (t) async {
      await _open(t);
      expect(_live(t).mosaics.length, 2);
      await _add(t, '自動碼人臉');
      expect(_faceCalls, 2);
      expect(_live(t).mosaics.length, 2, reason: '已經碼著的臉又加了一次');
      expect(find.text('找到的臉都已經碼上了'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      expect(t.takeException(), isNull);
    });

    testWidgets('從馬賽克模式存的草稿：開回馬賽克模式，不再自動找一次', (t) async {
      final st = MosaicStyle(type: 1);
      final s = WatermarkSettings()..text.enabled = false;
      s.mosaics.add(
        faceMosaic(const FaceBox(0.3, 0.3, 0.2, 0.2), 1000, 800, style: st),
      );
      final draft = jsonEncode({
        ...s.toJson(),
        'color': ColorGrade().toJson(),
        'extraWms': const [],
        'mosaicMode': true,
        'mzStyle': st.toJson(),
        'mzOval': true,
      });
      await _open(t, draft: draft);
      expect(_faceCalls, 0, reason: '草稿已經找過臉了');
      expect(find.text('新增馬賽克'), findsOneWidget, reason: '沒有開回馬賽克模式');
      expect(find.text('存成範本'), findsNothing);
      expect(_live(t).mosaics.single.face, isTrue);
      expect(t.takeException(), isNull);
    });

    testWidgets('照片上不畫框：碼著的臉、剛加的方框都沒有；點掉的臉才有虛線', (t) async {
      await _open(t);
      expect(_outlines(t), isEmpty, reason: '碼著的臉不該有框（使用者：馬賽克不要有邊框）');

      await _add(t, '方框');
      expect(_outlines(t), isEmpty, reason: '剛加的方框也不該有框');
      // 琥珀選取框（方形版是 Container 的邊框）也不能有
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).border ==
                  Border.all(color: const Color(0xFFFFC24B), width: 1.4),
        ),
        findsNothing,
      );

      await t.tapAt(_at(t, _live(t).mosaics.first));
      await _settle(t, 4);
      final lines = _outlines(t).toList();
      expect(lines.length, 1, reason: '點掉的臉要留一圈虛線（找得回來）');
      expect(lines.single.dashed, isTrue);
      // 亮一下的光暈要收得掉（計時器走完，測試才收得乾淨）
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull);
    });

    testWidgets('新增方框：放在空的地方，連加兩塊不會疊在一起', (t) async {
      await _open(t);
      await _add(t, '方框');
      await _add(t, '方框');
      final ms = _live(t).mosaics;
      expect(ms.length, 4);
      const w = 1000.0, h = 800.0;
      Rect r(PhotoMosaic m) => photoMosaicRect(m, w, h);
      double cover(Rect a, Rect b) {
        final o = a.intersect(b);
        if (o.width <= 0 || o.height <= 0) return 0;
        return o.width * o.height / (a.width * a.height);
      }

      final a = ms[2], b = ms[3];
      expect(
        (a.x - b.x).abs() + (a.y - b.y).abs(),
        greaterThan(0.1),
        reason: '第二塊疊在第一塊上（以前一律放正中央）',
      );
      expect(cover(r(b), r(a)), lessThan(0.5));
      for (final f in ms.take(2)) {
        expect(cover(r(a), r(f)), lessThan(0.2), reason: '新的一塊蓋到臉上了');
      }
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull);
    });

    testWidgets('大小：每一塊一起放大縮小；上一步退得回來', (t) async {
      await _open(t);
      await _add(t, '方框');
      final ms = _live(t).mosaics;
      final before = [for (final m in ms) m.scale];
      await t.drag(_sizeSlider(), const Offset(160, 0));
      await _settle(t, 4);
      final after = [for (final m in _live(t).mosaics) m.scale];
      final f = after[0] / before[0];
      expect(f, greaterThan(1.1), reason: '往右拉要變大');
      for (var i = 0; i < before.length; i++) {
        expect(
          after[i] / before[i],
          closeTo(f, 1e-6),
          reason: '第 ${i + 1} 塊沒有跟著一起變',
        );
      }
      await t.tap(find.byIcon(Icons.undo));
      await _settle(t, 4);
      final back = [for (final m in _live(t).mosaics) m.scale];
      for (var i = 0; i < before.length; i++) {
        expect(back[i], closeTo(before[i], 1e-9), reason: '上一步沒有退回來');
      }
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull);
    });

    testWidgets('縮圖：點臉的縮圖＝碼↔不碼；長按縮圖→刪除', (t) async {
      await _open(t);
      await t.tap(_thumb('臉').first);
      await _settle(t, 4);
      expect(_live(t).mosaics.first.off, isTrue, reason: '點臉的縮圖要切成不碼');
      expect(_thumb('沒碼的臉'), findsOneWidget);

      await t.longPress(_thumb('臉').first);
      await _settle(t, 6);
      expect(find.text('刪除'), findsOneWidget, reason: '長按要跳刪除小選單');
      await t.tap(find.text('刪除'));
      await _settle(t, 6);
      expect(_live(t).mosaics.length, 1);
      expect(_live(t).mosaics.single.off, isTrue, reason: '刪錯塊了');
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull);
    });

    testWidgets('長按照片上的一塊：壓暗＋刪除；取消就不刪', (t) async {
      await _open(t);
      final second = _live(t).mosaics[1];
      await t.longPressAt(_at(t, second));
      await _settle(t, 6);
      expect(find.text('刪除'), findsOneWidget);
      await t.tap(find.text('取消'));
      await _settle(t, 6);
      expect(_live(t).mosaics.length, 2, reason: '按取消卻刪掉了');

      await t.longPressAt(_at(t, second));
      await _settle(t, 6);
      await t.tap(find.text('刪除'));
      await _settle(t, 6);
      expect(_live(t).mosaics.length, 1);
      expect(_live(t).mosaics.contains(second), isFalse, reason: '刪錯塊了');
      expect(_live(t).mosaics.single.off, isFalse, reason: '長按不該順便切成不碼');
      expect(t.takeException(), isNull);
    });

    testWidgets('兩指捏臉：只有那張臉變大，不會順便切成不碼', (t) async {
      await _open(t);
      final ms = _live(t).mosaics;
      final a = ms[0], b = ms[1];
      final a0 = a.scale, b0 = b.scale;
      final c = _at(t, a);
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
      expect(a.scale, greaterThan(a0 * 1.5), reason: '捏的那張臉要變大');
      expect(b.scale, closeTo(b0, 1e-9), reason: '另一張臉不該跟著變');
      expect(a.off, isFalse, reason: '捏完放開那一下被當成「點」，臉被切成不碼');
      expect(t.takeException(), isNull);
    });

    testWidgets('小螢幕＋大字：面板不爆版（iPhone SE、字級 2.0）', (t) async {
      t.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      t.view.physicalSize = const Size(640, 1136);
      t.view.devicePixelRatio = 2.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: PhotoEditorScreen(
            photo: XFile(_photoPath, name: 'p.png', mimeType: 'image/png'),
            mosaicMode: true,
          ),
        ),
      );
      await _settle(t, 14);
      expect(_live(t).mosaics.length, 2);
      expect(find.text('新增馬賽克'), findsOneWidget);
      await _add(t, '方框');
      await t.pump(const Duration(seconds: 1));
      expect(t.takeException(), isNull, reason: '小螢幕大字爆版了');
    });

    testWidgets('拖完一塊方框，再在別處拖不會拖到它（沒有隱形的選取）', (t) async {
      await _open(t);
      await _add(t, '方框');
      await t.pump(const Duration(seconds: 1));
      final box = _live(t).mosaics.last;
      final x0 = box.x;
      await t.dragFrom(_at(t, box), const Offset(60, 0));
      await _settle(t, 4);
      final x1 = box.x;
      expect(x1, greaterThan(x0 + 0.03), reason: '方框拖不動');

      // 畫布左下角（離臉跟方框都遠）拖一下：方框不該跟著動
      final canvas = _canvas(t);
      await t.dragFrom(
        Offset(canvas.left + 12, canvas.bottom - 12),
        const Offset(60, 0),
      );
      await _settle(t, 4);
      expect(box.x, closeTo(x1, 1e-9), reason: '在別處拖曳卻拖走了剛剛那塊');
      expect(t.takeException(), isNull);
    });
  });
}
