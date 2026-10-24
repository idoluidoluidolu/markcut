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
import 'package:markcut/services/watermark_renderer.dart';
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
      for (final x in const ['像素化', '模糊', '純色', '找臉', '方框', '筆刷', '匯出']) {
        expect(find.text(x), findsWidgets, reason: '少了「$x」');
      }
      for (final x in const ['存成範本', '範本', '位置', '調色', '@我的浮水印']) {
        expect(find.text(x), findsNothing, reason: '馬賽克模式不該有「$x」');
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

      await t.tap(find.text('方框'));
      await _settle(t, 4);
      final ms = _live(t).mosaics;
      expect(ms.length, 3);
      expect(ms.last.face, isFalse);
      expect(ms.last.oval, isTrue, reason: '方框要照目前選的形狀（橢圓）');
      expect(ms.last.style.type, 2, reason: '方框要照目前選的樣式');

      // 形狀切成方的：每一塊都跟著變
      await t.tap(find.byIcon(Icons.crop_square).first);
      await _settle(t, 4);
      expect(_live(t).mosaics.every((m) => !m.oval), isTrue);
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
      await t.tap(find.text('找臉'));
      await _settle(t, 6);
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
      expect(find.text('找臉'), findsOneWidget, reason: '沒有開回馬賽克模式');
      expect(find.text('存成範本'), findsNothing);
      expect(_live(t).mosaics.single.face, isTrue);
      expect(t.takeException(), isNull);
    });
  });
}
