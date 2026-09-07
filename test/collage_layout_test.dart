// 照片拼圖自由模式的排版守門（iOS TestFlight 測試回報三件）：
//
// A. 換畫布比例，照片不能跟著變形——方塊是畫布的比例座標，以前只換
//    畫布比例、方塊跟著畫布伸縮，1:1 上的正方形到了 16:9 變成長條。
//    現在：自動排的照新畫布重排塞滿；使用者自己排過的整組等比縮放置中，
//    每一塊的像素形狀一模一樣、沒有一塊被擠出畫布
// B. 自由模式加照片：自動排滿整張畫布（≥90%）、每張都是照片的形狀、
//    不重疊；「隨機排列」換一種排法、照樣塞滿
// C. 拼圖的浮水印預設關；共用的預設不動；面板打開就有字、照樣能用
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/services/collage_pack.dart';
import 'package:markcut/widgets/watermark_layer.dart';
import 'package:markcut/widgets/watermark_panel.dart';

/// 假的相簿選取器：「加照片」拿到的就是 [next] 這批
class _Picker extends ImagePickerPlatform {
  List<XFile> next = const [];

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async => next;
}

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

/// 六張形狀各異的照片（3:2、2:3、1:1、16:9、9:16、4:3）
const _sizes = [
  (300, 200),
  (200, 300),
  (240, 240),
  (320, 180),
  (180, 320),
  (400, 300),
];

Future<List<XFile>> _photos(WidgetTester t, [int n = 6]) async {
  late List<Uint8List> bytes;
  await t.runAsync(() async {
    bytes = [
      for (var i = 0; i < n; i++)
        await _png(Color(0xFF400000 + i * 0x203040), _sizes[i].$1, _sizes[i].$2),
    ];
  });
  return [
    for (var i = 0; i < n; i++)
      XFile.fromData(bytes[i], name: 'p$i.png', mimeType: 'image/png'),
  ];
}

/// 等 _load 完成（輪詢直到轉圈圈消失）
Future<void> _waitLoaded(WidgetTester t) async {
  for (
    var i = 0;
    i < 50 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    i++
  ) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump();
  }
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

CollageLayoutPeek _peek(WidgetTester t) =>
    t.state(find.byType(CollageScreen)) as CollageLayoutPeek;

/// 目前每張照片的方塊（照片索引 → 方塊）。點選、拖曳會改疊放順序，
/// 照照片索引比才穩
Map<int, ui.Rect> _rects(WidgetTester t) => {
  for (final it in _peek(t).layout.items) it.img: it.rect,
};

double _imgAspect(WidgetTester t, int img) {
  final im = _peek(t).images[img]!;
  return im.width / im.height;
}

/// 方塊在畫布上的真實形狀（比例座標要乘回畫布比例）
double _px(ui.Rect r, double canvas) => r.width * canvas / r.height;

/// 這批方塊蓋住畫布的比例（100×100 取樣）
double _coverage(Iterable<ui.Rect> rs) {
  var hit = 0;
  for (var y = 0; y < 100; y++) {
    for (var x = 0; x < 100; x++) {
      final p = ui.Offset((x + 0.5) / 100, (y + 0.5) / 100);
      if (rs.any((r) => r.contains(p))) hit++;
    }
  }
  return hit / 10000;
}

/// 方塊落在畫布內的面積比例（1＝整塊都看得到）
double _visible(ui.Rect r) {
  final o = r.intersect(const ui.Rect.fromLTWH(0, 0, 1, 1));
  if (o.width <= 0 || o.height <= 0) return 0;
  return o.width * o.height / (r.width * r.height);
}

/// 兩批方塊有沒有不一樣
bool _differs(Map<int, ui.Rect> a, Map<int, ui.Rect> b) {
  if (a.length != b.length) return true;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null) return true;
    if ((o.left - e.value.left).abs() > 1e-6 ||
        (o.top - e.value.top).abs() > 1e-6 ||
        (o.width - e.value.width).abs() > 1e-6 ||
        (o.height - e.value.height).abs() > 1e-6) {
      return true;
    }
  }
  return false;
}

/// 自動排版該有的樣子：塞滿、全在畫布內、不重疊、每塊是照片的形狀
///（拉滿時允許差 kCollagePackMaxStretch）
void _expectFilled(WidgetTester t, Map<int, ui.Rect> rs, double canvas) {
  expect(_coverage(rs.values), greaterThanOrEqualTo(0.9), reason: '要塞滿畫布');
  final list = rs.values.toList();
  for (var i = 0; i < list.length; i++) {
    for (var j = i + 1; j < list.length; j++) {
      final o = list[i].intersect(list[j]);
      if (o.width > 0 && o.height > 0) {
        expect(o.width * o.height, lessThan(1e-6), reason: '方塊不該重疊');
      }
    }
  }
  for (final e in rs.entries) {
    expect(_visible(e.value), greaterThanOrEqualTo(1 - 1e-6), reason: '照片 ${e.key} 要在畫布內');
    expect(
      _px(e.value, canvas) / _imgAspect(t, e.key),
      closeTo(1, kCollagePackMaxStretch),
      reason: '照片 ${e.key} 的形狀跑掉了',
    );
  }
}

/// 進自由模式加這批照片，等解碼與排版完成
Future<void> _addPhotos(WidgetTester t, _Picker picker, List<XFile> files) async {
  picker.next = files;
  final before = _peek(t).layout.items.length;
  await t.tap(find.text('加照片'));
  for (
    var i = 0;
    i < 100 && _peek(t).layout.items.length < before + files.length;
    i++
  ) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump();
  }
  await t.pumpAndSettle();
  expect(_peek(t).layout.items.length, before + files.length);
}

/// 空手進拼圖頁、切到自由模式（假選取器裝好）
Future<_Picker> _openFree(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  final picker = _Picker();
  final prev = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = picker;
  addTearDown(() => ImagePickerPlatform.instance = prev);
  await t.pumpWidget(const MaterialApp(home: CollageScreen()));
  await _waitLoaded(t);
  await t.tap(find.text('自由'));
  await t.pumpAndSettle();
  return picker;
}

Finder _tab(String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

WatermarkLayer _layer(WidgetTester t) =>
    t.widget<WatermarkLayer>(find.byType(WatermarkLayer));

void main() {
  testWidgets('B 自由模式加照片：自動排滿整張畫布、每張都是照片的形狀；「隨機排列」換一種、照樣塞滿', (t) async {
    final picker = await _openFree(t);
    expect(find.text('加照片'), findsOneWidget);
    expect(find.text('隨機排列'), findsNothing, reason: '還沒有照片，沒東西可排');

    await _addPhotos(t, picker, await _photos(t));
    final l = _peek(t).layout;
    expect(l.free, isTrue);
    expect(l.canvasAspect, closeTo(1, 1e-9));
    final first = _rects(t);
    expect(first.length, 6);
    _expectFilled(t, first, 1);

    // 隨機排列：換一種排法、照樣塞滿；再按又換一種
    expect(find.text('隨機排列'), findsOneWidget);
    await t.tap(find.text('隨機排列'));
    await t.pumpAndSettle();
    final second = _rects(t);
    expect(_differs(first, second), isTrue, reason: '隨機排列要換一種排法');
    _expectFilled(t, second, 1);
    await t.tap(find.text('隨機排列'));
    await t.pumpAndSettle();
    final third = _rects(t);
    expect(_differs(second, third), isTrue, reason: '再按一次要再換');
    _expectFilled(t, third, 1);

    // 再加兩張：連同原本的一起重排，八張還是塞滿
    await _addPhotos(t, picker, (await _photos(t, 2)));
    final eight = _rects(t);
    expect(eight.length, 8);
    _expectFilled(t, eight, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('A 換畫布比例照片不變形：自動排的重排塞滿新畫布；自己排過的等比縮放置中、形狀一模一樣、沒有一塊被擠出去', (t) async {
    final picker = await _openFree(t);
    await _addPhotos(t, picker, await _photos(t));
    final on11 = _rects(t);
    _expectFilled(t, on11, 1);

    // 沒動過：換 16:9 → 照新畫布重排塞滿，每塊還是照片的形狀
    await t.tap(find.text('16:9'));
    await t.pumpAndSettle();
    expect(_peek(t).layout.canvasAspect, closeTo(16 / 9, 1e-9));
    final on169 = _rects(t);
    _expectFilled(t, on169, 16 / 9);
    // 以前的 bug：比例座標不動、畫布變寬，每一塊的形狀都被拉成 1.78 倍。
    // 重排前後每塊的形狀都在拉滿容許值內，所以前後相比不會差過它的平方
    final sq = (1 + kCollagePackMaxStretch) * (1 + kCollagePackMaxStretch);
    for (final e in on169.entries) {
      expect(
        _px(e.value, 16 / 9) / _px(on11[e.key]!, 1),
        inInclusiveRange(1 / sq, sq),
        reason: '照片 ${e.key} 的形狀跟著畫布跑了',
      );
    }

    // 自己動過一塊（拖一下）：之後換比例不重排，整組等比縮放置中
    final canvas = t.getRect(find.byType(AspectRatio).first);
    final c = _peek(t).layout.items.first.rect.center;
    await t.dragFrom(
      Offset(canvas.left + c.dx * canvas.width, canvas.top + c.dy * canvas.height),
      const Offset(25, 15),
    );
    await t.pumpAndSettle();
    final moved = _rects(t);
    expect(_differs(on169, moved), isTrue, reason: '拖曳要真的動到方塊');

    await t.tap(find.text('9:16'));
    await t.pumpAndSettle();
    expect(_peek(t).layout.canvasAspect, closeTo(9 / 16, 1e-9));
    final on916 = _rects(t);
    expect(_differs(moved, on916), isTrue);
    for (final e in on916.entries) {
      final was = moved[e.key]!;
      expect(
        _px(e.value, 9 / 16) / _px(was, 16 / 9),
        closeTo(1, 1e-6),
        reason: '照片 ${e.key} 的形狀變了',
      );
      expect(
        _visible(e.value),
        greaterThanOrEqualTo(_visible(was) - 1e-6),
        reason: '照片 ${e.key} 被擠出畫布',
      );
    }
    // 相對位置也沒變：整組的外框只是等比縮放（像素形狀一樣）
    ui.Rect bbox(Map<int, ui.Rect> rs) =>
        rs.values.reduce((a, b) => a.expandToInclude(b));
    expect(
      _px(bbox(on916), 9 / 16) / _px(bbox(moved), 16 / 9),
      closeTo(1, 1e-6),
      reason: '整組的形狀變了＝不是等比縮放',
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('窄螢幕：375（SE／mini）三顆動作鈕全都看得到、照順序；320 不溢出、「加照片」永遠貼右', (t) async {
    for (final width in const [375.0, 320.0]) {
      t.view.physicalSize = Size(width, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final picker = await _openFree(t);
      await _addPhotos(t, picker, await _photos(t, 3));
      // 剛加完最後一張是選取中的：移除／隨機排列／加照片三顆都在
      expect(find.text('移除'), findsOneWidget, reason: '$width 寬');
      expect(find.text('隨機排列'), findsOneWidget, reason: '$width 寬');
      expect(find.text('加照片'), findsOneWidget, reason: '$width 寬');
      final add = t.getRect(find.text('加照片'));
      expect(add.right, lessThanOrEqualTo(width - 16), reason: '$width 寬：加照片要在畫面內');
      if (width >= 375) {
        final rm = t.getRect(find.text('移除'));
        final sh = t.getRect(find.text('隨機排列'));
        expect(rm.left, greaterThanOrEqualTo(16), reason: '375 寬：移除不能被擠出去');
        expect(rm.right, lessThan(sh.left));
        expect(sh.right, lessThan(add.left));
        // 跟模式膠囊不同列（同一列擠不下才拆的）
        expect(rm.top, greaterThan(t.getRect(find.text('自由')).bottom));
      }
      // 溢出會在這裡以例外冒出來
      expect(t.takeException(), isNull, reason: '$width 寬');
    }
  });

  testWidgets('C 拼圖的浮水印預設關；共用的預設不動；面板打開就有字、切進浮水印分頁會自動選', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(
      MaterialApp(home: CollageScreen(photos: await _photos(t, 2))),
    );
    await _waitLoaded(t);
    final wm = _layer(t).settings;
    expect(wm.text.enabled, isFalse, reason: '拼圖的文字浮水印預設關');
    expect(wm.logo.enabled, isFalse);
    expect(wm.hasAnyMark, isFalse);
    expect(wm.text.text.trim(), isNotEmpty, reason: '文字內容留著，一開就有字');
    expect(WatermarkSettings().text.enabled, isTrue, reason: '只改拼圖的預設，共用的不動');

    // 切進浮水印分頁：沒有開著的部件，不會硬選一個
    await t.tap(_tab('浮水印'));
    await t.pumpAndSettle();
    expect(_layer(t).selectedPart, WmPart.none);

    // 面板導覽點「文字」，那一區最上面那顆開關就是文字的開關：
    // 打開 → 有浮水印（使用者要開就是走這條路）
    await t.tap(
      find.descendant(of: find.byType(WatermarkPanel), matching: find.text('文字')).first,
    );
    await t.pumpAndSettle();
    final sw = find.byType(Switch).first;
    await t.ensureVisible(sw);
    await t.tap(sw);
    await t.pumpAndSettle();
    expect(wm.text.enabled, isTrue);
    expect(wm.hasAnyMark, isTrue);

    // 開了之後跟以前一樣：離開再切回來就自動選起來
    await t.tap(_tab('拼圖'));
    await t.pumpAndSettle();
    await t.tap(_tab('浮水印'));
    await t.pumpAndSettle();
    expect(_layer(t).selectedPart, WmPart.text);
    expect(t.takeException(), isNull);
  });
}
