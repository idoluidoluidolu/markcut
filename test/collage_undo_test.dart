// 拼圖的上一步／重做（使用者：「照片拼圖這裡加入一個上一步下一步的按鈕」）。
// 跟影片、照片、批次同一條列、同一個位置（預覽下方，三個分頁都在）。
//
// 拼圖是「改完對帳」：記著上一個定案的狀態，畫面因為改動重建之後比一次，
// 不一樣才算一步。這裡守的是：
// - 自由模式：拖、複製、移除、層級、換比例，每一步都退得回去、也重做得回來；
//   一整個拖曳只算一步；退回去之後再改別的，重做就沒了
// - 宮格：加減欄列、拖曳互換、格線開關各一步；格線間距一整段拖曳只算一步；
//   宮格／自由切換也退得回去
// - 照片池：被移除、被上一步退掉的照片先留著（重做拿得回來），等重做的路線
//   沒了才釋放；留著的不會自己跑回宮格的空格
// - 浮水印分頁：連續打字併成一步；退回去面板的輸入框跟著對回來
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/services/collage_compose.dart';
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

/// 一張照片一個（寬, 高），顏色輪流
Future<List<XFile>> _photos(WidgetTester t, List<(int, int)> sizes) async {
  late List<Uint8List> bytes;
  await t.runAsync(() async {
    bytes = [
      for (var i = 0; i < sizes.length; i++)
        await _png(
          Color(0xFF000000 | ((0x402010 + i * 0x2B3D4F) & 0xFFFFFF)),
          sizes[i].$1,
          sizes[i].$2,
        ),
    ];
  });
  return [
    for (var i = 0; i < sizes.length; i++)
      XFile.fromData(bytes[i], name: 'p$i.png', mimeType: 'image/png'),
  ];
}

CollageLayoutPeek _peek(WidgetTester t) =>
    t.state(find.byType(CollageScreen)) as CollageLayoutPeek;

List<CollageFreeItem> _items(WidgetTester t) => _peek(t).layout.items;

List<ui.Rect> _rects(WidgetTester t) => [for (final it in _items(t)) it.rect];

List<int> _imgs(WidgetTester t) => [for (final it in _items(t)) it.img];

/// 上一步／重做鈕現在按不按得下去
bool _can(WidgetTester t, String tip) =>
    t
        .widget<IconButton>(
          find.ancestor(
            of: find.byTooltip(tip),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed !=
    null;

/// 對帳排在畫完那一格之後、按鈕亮起來又是下一格：多走幾格
Future<void> _frames(WidgetTester t, [int n = 3]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _undo(WidgetTester t) async {
  await t.tap(find.byTooltip('上一步'));
  await _frames(t);
}

Future<void> _redo(WidgetTester t) async {
  await t.tap(find.byTooltip('重做'));
  await _frames(t);
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
  await _frames(t);
}

/// iPhone 大小的畫面＋假選取器（安卓的系統相片選取器 markcut/pick 回
/// null＝這台沒有，退到 image_picker）
_Picker _setUp(WidgetTester t) {
  SharedPreferences.setMockInitialValues({});
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final picker = _Picker();
  final prev = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = picker;
  addTearDown(() => ImagePickerPlatform.instance = prev);
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
  return picker;
}

/// 空手進拼圖頁、切到自由模式
Future<_Picker> _openFree(WidgetTester t) async {
  final picker = _setUp(t);
  await t.pumpWidget(const MaterialApp(home: CollageScreen()));
  await _waitLoaded(t);
  await t.tap(find.text('自由'));
  await t.pumpAndSettle();
  return picker;
}

/// 按「加照片」加這批，等解碼完、方塊放上畫布
Future<void> _addPhotos(
  WidgetTester t,
  _Picker picker,
  List<XFile> files,
) async {
  picker.next = files;
  final want = _items(t).length + files.length;
  await t.tap(find.text('加照片'));
  for (var i = 0; i < 200 && _items(t).length < want; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump();
  }
  await _frames(t);
  expect(_items(t).length, want);
}

/// 自由模式那張畫布在螢幕上的範圍
Rect _canvas(WidgetTester t) => t.getRect(
  find
      .ancestor(
        of: find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              w.painter.runtimeType.toString().contains('FreePainter'),
        ),
        matching: find.byType(GestureDetector),
      )
      .first,
);

Offset _at(WidgetTester t, Offset p) {
  final c = _canvas(t);
  return Offset(c.left + p.dx * c.width, c.top + p.dy * c.height);
}

/// 點一塊的中心把它選起來（被別塊蓋住的話，同一點再點一下會往下一層輪）
Future<void> _select(WidgetTester t, int i) async {
  for (var k = 0; k < _items(t).length && _peek(t).selItem != i; k++) {
    await t.tapAt(_at(t, _items(t)[i].rect.center));
    await t.pump(const Duration(milliseconds: 300));
    await _frames(t);
  }
  expect(_peek(t).selItem, i, reason: '點到的要被選起來');
}

/// 單指拖一塊：按下、先走過拖曳門檻，再分幾段走完（一整個手勢）
Future<void> _dragItem(WidgetTester t, int i, Offset delta) async {
  final from = _at(t, _items(t)[i].rect.center);
  final g = await t.startGesture(from);
  await t.pump();
  var p = from + const Offset(20, 0);
  await g.moveTo(p);
  await t.pump();
  for (var k = 1; k <= 4; k++) {
    p = from + const Offset(20, 0) + delta * (k / 4);
    await g.moveTo(p);
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await _frames(t);
}

Future<void> _tapChip(WidgetTester t, String label) async {
  await t.ensureVisible(find.text(label));
  await t.pumpAndSettle();
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('上一步／重做在預覽下方，三個分頁都在；一開始兩顆都按不下去', (t) async {
    _setUp(t);
    await t.pumpWidget(const MaterialApp(home: CollageScreen()));
    await _waitLoaded(t);
    final preview = t.getRect(find.byType(WatermarkLayer));
    for (final tab in ['拼圖', '浮水印', '匯出']) {
      await t.tap(
        find.descendant(of: find.byType(TabBar), matching: find.text(tab)),
      );
      await t.pumpAndSettle();
      expect(find.byTooltip('上一步'), findsOneWidget, reason: tab);
      expect(find.byTooltip('重做'), findsOneWidget, reason: tab);
      expect(_can(t, '上一步'), isFalse, reason: '$tab：還沒動過');
      expect(_can(t, '重做'), isFalse, reason: tab);
      expect(
        t.getRect(find.byTooltip('上一步')).top,
        greaterThanOrEqualTo(
          tab == '浮水印'
              ? t.getRect(find.byType(WatermarkLayer)).bottom
              : preview.bottom,
        ),
        reason: '$tab：在預覽下面',
      );
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('自由模式：拖、複製、移除、層級、換比例，每一步都退得回去也重做得回來', (t) async {
    final picker = await _openFree(t);
    await _addPhotos(
      t,
      picker,
      await _photos(t, [(300, 200), (200, 300), (260, 260)]),
    );
    expect(_can(t, '上一步'), isTrue, reason: '加照片就是一步');
    expect(_can(t, '重做'), isFalse);

    // 拖一塊：一整個手勢只算一步
    final r0 = _rects(t);
    await _select(t, 0);
    await _dragItem(t, 0, const Offset(60, 40));
    final r1 = _rects(t);
    expect(r1, isNot(r0), reason: '拖得動');
    await _undo(t);
    expect(_rects(t), r0, reason: '一次上一步就退回拖之前');
    expect(_can(t, '重做'), isTrue);
    await _redo(t);
    expect(_rects(t), r1);
    expect(_can(t, '重做'), isFalse);

    // 複製
    await _select(t, 0);
    await t.tap(find.text('複製'));
    await _frames(t);
    expect(_items(t).length, 4);
    await _undo(t);
    expect(_items(t).length, 3);
    expect(_rects(t), r1);
    await _redo(t);
    expect(_items(t).length, 4);
    final dup = _rects(t);

    // 層級：複製出來的那塊壓在原本那塊上面，原本那塊往上一層
    await _select(t, 0);
    await t.tap(find.byKey(const ValueKey('collage-layer-up')));
    await _frames(t);
    final layered = _rects(t);
    expect(layered, isNot(dup), reason: '疊放順序換了');
    await _undo(t);
    expect(_rects(t), dup);
    await _redo(t);
    expect(_rects(t), layered);

    // 移除一張只有它在用的照片：照片先留著，上一步拿得回來
    final lone = _items(
      t,
    ).indexWhere((it) => _imgs(t).where((k) => k == it.img).length == 1);
    expect(lone, isNot(-1));
    final loneImg = _items(t)[lone].img;
    await _select(t, lone);
    await t.tap(find.text('移除'));
    await _frames(t);
    expect(_imgs(t), isNot(contains(loneImg)));
    expect(_peek(t).images[loneImg], isNotNull, reason: '上一步還用得到，不能放掉');
    await _undo(t);
    expect(_imgs(t), contains(loneImg));
    expect(_rects(t), layered);

    // 換畫布比例（方塊跟著搬）也是一步；退回去之後再改別的，重做就沒了
    await _tapChip(t, '16:9');
    expect(_peek(t).layout.canvasAspect, closeTo(16 / 9, 1e-9));
    await _undo(t);
    expect(_peek(t).layout.canvasAspect, 1);
    expect(_rects(t), layered);
    expect(_can(t, '重做'), isTrue);
    await _tapChip(t, '4:5');
    expect(_can(t, '重做'), isFalse, reason: '改了新的東西，重做的路線就斷了');
    await _undo(t);
    expect(_peek(t).layout.canvasAspect, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('加照片退掉：重做還拿得回來；重做的路線沒了那張照片才放掉', (t) async {
    final picker = await _openFree(t);
    await _addPhotos(t, picker, await _photos(t, [(300, 200), (200, 300)]));
    await _addPhotos(t, picker, await _photos(t, [(260, 260)]));
    final added = _items(t).last.img;
    await _undo(t);
    expect(_items(t).length, 2);
    expect(_imgs(t), isNot(contains(added)));
    expect(_peek(t).images[added], isNotNull, reason: '重做還要用');
    await _redo(t);
    expect(_items(t).length, 3);
    expect(_imgs(t), contains(added));
    await _undo(t);
    await _tapChip(t, '16:9');
    expect(_can(t, '重做'), isFalse);
    expect(_peek(t).images[added], isNull, reason: '沒有任何一步用得到了，放掉');
    expect(t.takeException(), isNull);
  });

  testWidgets('宮格：加減欄列、拖曳互換、格線開關各一步；間距一整段拖曳只算一步；切自由也退得回去', (t) async {
    _setUp(t);
    await t.pumpWidget(
      MaterialApp(
        home: CollageScreen(
          photos: await _photos(t, [
            (300, 200),
            (200, 300),
            (260, 260),
            (320, 240),
          ]),
        ),
      ),
    );
    await _waitLoaded(t);
    final l0 = _peek(t).layout;
    expect((l0.cols, l0.rows), (2, 2));
    final order0 = List.of(l0.order);

    // 欄 +1
    final colPlus = find.descendant(
      of: find.ancestor(of: find.text('欄'), matching: find.byType(Row)).first,
      matching: find.byIcon(Icons.add),
    );
    await t.ensureVisible(colPlus);
    await t.pumpAndSettle();
    await t.tap(colPlus);
    await _frames(t);
    expect(_peek(t).layout.cols, 3);
    await _undo(t);
    expect(_peek(t).layout.cols, 2);
    expect(_peek(t).layout.order, order0);
    await _redo(t);
    expect(_peek(t).layout.cols, 3);
    await _undo(t);

    // 按住拿起第一格、拖到第二格互換
    final grid = t.getRect(find.byType(AspectRatio).first);
    final a = Offset(
      grid.left + grid.width * 0.25,
      grid.top + grid.height * 0.25,
    );
    final b = Offset(
      grid.left + grid.width * 0.75,
      grid.top + grid.height * 0.25,
    );
    final g = await t.startGesture(a);
    await t.pump(const Duration(milliseconds: 260));
    await g.moveTo(a + const Offset(30, 0));
    await t.pump();
    await g.moveTo(b);
    await t.pump();
    await g.up();
    await _frames(t);
    final swapped = List.of(_peek(t).layout.order);
    expect(swapped, [order0[1], order0[0], ...order0.skip(2)]);
    await _undo(t);
    expect(_peek(t).layout.order, order0);
    await _redo(t);
    expect(_peek(t).layout.order, swapped);

    // 格線開關，再一整段拖間距
    await t.ensureVisible(find.byType(Switch));
    await t.pumpAndSettle();
    await t.tap(find.byType(Switch));
    await _frames(t);
    expect(_peek(t).layout.lines, isTrue);
    final gap0 = _peek(t).layout.gapN;
    final slider = find.byType(Slider);
    await t.ensureVisible(slider);
    await t.pumpAndSettle();
    final s = t.getRect(slider);
    final sg = await t.startGesture(s.centerLeft + const Offset(30, 0));
    await t.pump();
    for (var k = 1; k <= 5; k++) {
      await sg.moveTo(s.centerLeft + Offset(30 + 25.0 * k, 0));
      await t.pump(const Duration(milliseconds: 16));
      await _frames(t, 2); // 拖動中畫面照常重建，但不能每一格都算一步
    }
    await sg.up();
    await _frames(t);
    expect(_peek(t).layout.gapN, isNot(gap0));
    await _undo(t);
    expect(_peek(t).layout.gapN, gap0, reason: '一整段拖曳一次退完');
    expect(_peek(t).layout.lines, isTrue, reason: '格線開關是前一步');
    await _undo(t);
    expect(_peek(t).layout.lines, isFalse);
    expect(_peek(t).layout.order, swapped);

    // 切自由（方塊照宮格的位置長出來）再退回宮格
    await _tapChip(t, '自由');
    expect(_peek(t).layout.free, isTrue);
    await _undo(t);
    expect(_peek(t).layout.free, isFalse);
    expect(_peek(t).layout.order, swapped);
    expect(t.takeException(), isNull);
  });

  testWidgets('宮格換掉的照片：上一步先留著、不會自己跑回加大後的空格', (t) async {
    final picker = _setUp(t);
    await t.pumpWidget(
      MaterialApp(
        home: CollageScreen(
          photos: await _photos(t, [(300, 200), (200, 300), (260, 260)]),
        ),
      ),
    );
    await _waitLoaded(t);
    // 2×2 放了三張：點空格補一張進來（那張是後來加的）
    final order0 = List.of(_peek(t).layout.order);
    expect(order0.where((k) => k < 0).length, 1);
    picker.next = await _photos(t, [(320, 240)]);
    await t.tap(find.byIcon(Icons.add).first);
    for (
      var i = 0;
      i < 100 && _peek(t).layout.order.where((k) => k >= 0).length < 4;
      i++
    ) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
    }
    await _frames(t);
    final order1 = List.of(_peek(t).layout.order);
    final added = order1.firstWhere((k) => k >= 0 && !order0.contains(k));
    // 退掉這一步：那張照片從格子裡拿掉，但重做還要用
    await _undo(t);
    expect(_peek(t).layout.order, isNot(contains(added)));
    expect(_peek(t).images[added], isNotNull);
    // 加大宮格：多出來的空格不能被退掉的那張自己補上
    final colPlus = find.descendant(
      of: find.ancestor(of: find.text('欄'), matching: find.byType(Row)).first,
      matching: find.byIcon(Icons.add),
    );
    await t.ensureVisible(colPlus);
    await t.pumpAndSettle();
    await t.tap(colPlus);
    await _frames(t);
    expect(_peek(t).layout.order, isNot(contains(added)));
    expect(_peek(t).images[added], isNull, reason: '重做的路線斷了，放掉');
    expect(t.takeException(), isNull);
  });

  testWidgets('浮水印分頁：連續打字併成一步；退回去輸入框跟著對回來', (t) async {
    _setUp(t);
    await t.pumpWidget(const MaterialApp(home: CollageScreen()));
    await _waitLoaded(t);
    await t.tap(
      find.descendant(of: find.byType(TabBar), matching: find.text('浮水印')),
    );
    await t.pumpAndSettle();
    await t.tap(
      find
          .descendant(
            of: find.byType(WatermarkPanel),
            matching: find.text('文字'),
          )
          .first,
    );
    await t.pumpAndSettle();
    final wm = t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).settings;
    final original = wm.text.text;
    // 文字卡標頭的開關打開
    final enable = find.descendant(
      of: find
          .ancestor(of: find.byTooltip('再加一個文字'), matching: find.byType(Row))
          .first,
      matching: find.byType(Switch),
    );
    await t.ensureVisible(enable);
    await t.pumpAndSettle();
    await t.tap(enable);
    await t.pump(const Duration(milliseconds: 800));
    await _frames(t);
    expect(wm.text.enabled, isTrue);
    expect(_can(t, '上一步'), isTrue);

    final input = find.byKey(const ValueKey('watermark-text-input'));
    await t.ensureVisible(input);
    await t.pumpAndSettle();
    for (final s in ['我', '我的', '我的拼', '我的拼圖']) {
      await t.enterText(input, s);
      await t.pump(const Duration(milliseconds: 120));
    }
    await t.pump(const Duration(milliseconds: 800));
    await _frames(t);
    expect(wm.text.text, '我的拼圖');

    await _undo(t);
    final now = t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).settings;
    expect(now.text.text, original, reason: '整段打字一次退完');
    expect(now.text.enabled, isTrue, reason: '打開文字是前一步');
    expect(t.widget<TextField>(input).controller!.text, original);
    await _undo(t);
    expect(
      t
          .widget<WatermarkLayer>(find.byType(WatermarkLayer))
          .settings
          .text
          .enabled,
      isFalse,
    );
    await _redo(t);
    await _redo(t);
    expect(
      t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).settings.text.text,
      '我的拼圖',
    );
    expect(t.widget<TextField>(input).controller!.text, '我的拼圖');
    expect(t.takeException(), isNull);
  });
}
