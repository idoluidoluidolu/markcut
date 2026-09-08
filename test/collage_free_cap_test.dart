// 照片拼圖自由模式的幾件守門（稽核 #2、#7、#8、#11、#14、#22）：
//
// - 自由模式「加照片」也守 30 張上限，超過的略過並講清楚
// - 進場帶超過 30 張：截斷要講，不能默默吞掉
// - 三張以上疊在同一處，連點要輪得到每一張（以前永遠在前兩張之間來回）
// - 一張照片沒有「隨機排列」（只有一種排法，按了沒反應）
// - 手排過的方塊換畫布比例來回切，回到原比例要一模一樣（以前每趟再縮一截）
// - 壞掉的草稿（6×6）也守 30 格
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/collage_screen.dart';

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

/// n 張小照片（形狀輪流：橫、直、方）
Future<List<XFile>> _photos(WidgetTester t, int n) async {
  late List<Uint8List> bytes;
  const shapes = [(60, 40), (40, 60), (48, 48)];
  await t.runAsync(() async {
    bytes = [
      for (var i = 0; i < n; i++)
        await _png(
          Color(0xFF400000 + (i * 0x203040) & 0xFFFFFF),
          shapes[i % 3].$1,
          shapes[i % 3].$2,
        ),
    ];
  });
  return [
    for (var i = 0; i < n; i++)
      XFile.fromData(bytes[i], name: 'p$i.png', mimeType: 'image/png'),
  ];
}

Future<void> _waitLoaded(WidgetTester t) async {
  for (
    var i = 0;
    i < 80 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
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

Map<int, ui.Rect> _rects(WidgetTester t) => {
  for (final it in _peek(t).layout.items) it.img: it.rect,
};

/// 進自由模式加這批照片，等到方塊數到 [expectTotal]（上限截掉的不會出現）
Future<void> _addPhotos(
  WidgetTester t,
  _Picker picker,
  List<XFile> files, {
  int? expectTotal,
}) async {
  picker.next = files;
  final want = expectTotal ?? _peek(t).layout.items.length + files.length;
  await t.tap(find.text('加照片'));
  for (var i = 0; i < 200 && _peek(t).layout.items.length < want; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump();
  }
  await t.pump(const Duration(milliseconds: 100));
  expect(_peek(t).layout.items.length, want);
}

/// 空手進拼圖頁、切到自由模式（假選取器裝好）
Future<_Picker> _openFree(WidgetTester t) async {
  SharedPreferences.setMockInitialValues({});
  final picker = _Picker();
  final prev = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = picker;
  addTearDown(() => ImagePickerPlatform.instance = prev);
  // 安卓的系統相片選取器（markcut/pick）：回 null＝這台沒有，退到
  // image_picker（跟 home_screen_test 同一套）。不掛的話 fake-async 裡
  // MissingPluginException 的回覆永遠送不到，假選取器就開不起來
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
  await t.pumpWidget(const MaterialApp(home: CollageScreen()));
  await _waitLoaded(t);
  await t.tap(find.text('自由'));
  await t.pumpAndSettle();
  return picker;
}

void _expectSameRects(Map<int, ui.Rect> a, Map<int, ui.Rect> b, String why) {
  expect(a.length, b.length, reason: why);
  for (final e in a.entries) {
    final o = b[e.key]!;
    expect(
      o.left,
      closeTo(e.value.left, 1e-9),
      reason: '$why：照片 ${e.key} left',
    );
    expect(o.top, closeTo(e.value.top, 1e-9), reason: '$why：照片 ${e.key} top');
    expect(
      o.width,
      closeTo(e.value.width, 1e-9),
      reason: '$why：照片 ${e.key} width',
    );
    expect(
      o.height,
      closeTo(e.value.height, 1e-9),
      reason: '$why：照片 ${e.key} height',
    );
  }
}

void main() {
  testWidgets('自由模式「加照片」一次 36 張：只收 30 張、講清楚略過了 6 張；再加一張也進不來', (t) async {
    final picker = await _openFree(t);
    await _addPhotos(t, picker, await _photos(t, 36), expectTotal: 30);
    expect(find.text('最多 30 張，已略過 6 張'), findsOneWidget);
    expect(_peek(t).images.where((i) => i != null).length, 30);
    // 滿了再加：一張都進不來、照樣提醒
    await t.pump(const Duration(seconds: 4)); // 上一則提示收掉
    await _addPhotos(t, picker, await _photos(t, 1), expectTotal: 30);
    expect(find.text('最多 30 張，已略過 1 張'), findsOneWidget);
    // 提示卡的計時器跑完，不留 pending timer
    await t.pump(const Duration(seconds: 4));
    expect(t.takeException(), isNull);
  });

  testWidgets('進場帶 31 張：只收 30 張、要講略過了 1 張', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(
      MaterialApp(home: CollageScreen(photos: await _photos(t, 31))),
    );
    await _waitLoaded(t);
    expect(_peek(t).images.length, 30);
    expect(find.text('最多 30 張，已略過 1 張'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
    expect(t.takeException(), isNull);
  });

  testWidgets('一張照片沒有「隨機排列」；兩張才有', (t) async {
    final picker = await _openFree(t);
    await _addPhotos(t, picker, await _photos(t, 1));
    expect(find.text('隨機排列'), findsNothing, reason: '一張只有一種排法');
    expect(find.text('加照片'), findsOneWidget);
    await _addPhotos(t, picker, await _photos(t, 1));
    expect(find.text('隨機排列'), findsOneWidget);
  });

  testWidgets('三張疊在同一處：連點四下，三張都輪得到（最後選取的在最上層）', (t) async {
    final picker = await _openFree(t);
    await _addPhotos(t, picker, await _photos(t, 3));
    // 三塊全部疊到同一個位置（測試鉤子給的是畫面上那幾份本人）
    for (final it in _peek(t).layout.items) {
      it.rect = const ui.Rect.fromLTWH(0.3, 0.3, 0.4, 0.4);
    }
    await t.pump();
    final canvas = t.getRect(find.byType(AspectRatio).first);
    final at = Offset(
      canvas.left + canvas.width * 0.5,
      canvas.top + canvas.height * 0.5,
    );
    final seen = <int>[];
    for (var k = 0; k < 4; k++) {
      await t.tapAt(at);
      await t.pump(const Duration(milliseconds: 350));
      // 選到誰誰就被帶到最上層＝清單最後一個
      seen.add(_peek(t).layout.items.last.img);
    }
    expect(seen.toSet().length, 3, reason: '連點四下應該三張都輪到，實際序列 $seen');
    expect(t.takeException(), isNull);
  });

  testWidgets('手排過的方塊換畫布比例來回切：回到原比例一模一樣，不會愈縮愈小', (t) async {
    final picker = await _openFree(t);
    await _addPhotos(t, picker, await _photos(t, 3));
    // 拖一塊＝手排過（之後換比例不重排）
    final canvas = t.getRect(find.byType(AspectRatio).first);
    final c = _peek(t).layout.items.first.rect.center;
    await t.dragFrom(
      Offset(
        canvas.left + c.dx * canvas.width,
        canvas.top + c.dy * canvas.height,
      ),
      const Offset(25, 15),
    );
    await t.pumpAndSettle();
    final on11 = _rects(t);

    await t.tap(find.text('16:9'));
    await t.pumpAndSettle();
    final on169 = _rects(t);
    await t.tap(find.text('1:1'));
    await t.pumpAndSettle();
    _expectSameRects(_rects(t), on11, '1:1→16:9→1:1 之後');

    // 繞一圈再回來也一樣；中途回到 16:9 也要跟第一次去 16:9 一樣
    await t.tap(find.text('16:9'));
    await t.pumpAndSettle();
    _expectSameRects(_rects(t), on169, '第二次到 16:9');
    await t.tap(find.text('9:16'));
    await t.pumpAndSettle();
    await t.tap(find.text('3:4'));
    await t.pumpAndSettle();
    await t.tap(find.text('1:1'));
    await t.pumpAndSettle();
    _expectSameRects(_rects(t), on11, '繞一圈回到 1:1');

    // 在別的比例上再動一塊：那一份就是新的原稿
    await t.tap(find.text('9:16'));
    await t.pumpAndSettle();
    final canvas2 = t.getRect(find.byType(AspectRatio).first);
    final c2 = _peek(t).layout.items.first.rect.center;
    await t.dragFrom(
      Offset(
        canvas2.left + c2.dx * canvas2.width,
        canvas2.top + c2.dy * canvas2.height,
      ),
      const Offset(-20, 30),
    );
    await t.pumpAndSettle();
    final on916 = _rects(t);
    await t.tap(find.text('1:1'));
    await t.pumpAndSettle();
    await t.tap(find.text('9:16'));
    await t.pumpAndSettle();
    _expectSameRects(_rects(t), on916, '新原稿：9:16→1:1→9:16');
    expect(t.takeException(), isNull);
  });

  testWidgets('壞掉的草稿 6×6：還原後總格數守 30', (t) async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('collage_cap_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final pa = '${dir.path}${Platform.pathSeparator}a.png';
    await t.runAsync(() async {
      File(pa).writeAsBytesSync(await _png(const Color(0xFFFF0000), 60, 40));
    });
    final draft =
        jsonDecode(
              jsonEncode({
                'photos': [pa],
                'order': [0],
                'cols': 6,
                'rows': 6,
                'free': false,
                'aspect': 1.0,
              }),
            )
            as Map<String, dynamic>;
    await t.pumpWidget(MaterialApp(home: CollageScreen(restore: draft)));
    await _waitLoaded(t);
    expect(_peek(t).layout.cellCount, lessThanOrEqualTo(30));
    expect(_peek(t).layout.cellCount, 30);
    expect(t.takeException(), isNull);
  });
}
