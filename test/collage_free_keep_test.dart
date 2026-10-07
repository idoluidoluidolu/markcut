// 拼圖自由模式：排好之後加照片，排好的不能被打回預設（測試回報：「已經
// 排好後 點加入照片 排好的會變成預設的樣子」），以及「已選」那一列的
// 「複製」（測試回報：「加入複製功能」）。
//
// 以前加照片不管有沒有排過，都把整組照片（連同使用者拖好、拉好的）重新
// 自動排滿。現在：
// - 自己拖過、拉過角之後加照片：原本每一塊的位置大小一模一樣；新的疊在
//   最上層、整塊在畫布內、大小像樣、是照片的形狀、被選起來；一次加兩張
//   彼此不疊；一張一張加也不會剛好疊在上一張新的上面
// - 還沒動過（自動排的、只點選過、按過隨機排列）：照舊連同原本的一起
//   自動重排
// - 續作的草稿：當初是使用者排的就不重排，當初是自動排的照舊重排
// - 複製：同一張照片、同樣的裁切與大小，錯開一點、在畫布內、疊在最上層、
//   選起來；算「動過」（之後加照片不重排）；貼著畫布邊的往回錯；同一張
//   連複製兩次不疊在一起；換畫布比例時兩塊各走各的、切回來一模一樣
// - 草稿：兩塊指著同一張照片，存起來、續作回來還是兩塊、同一張圖、
//   位置與裁切都在
import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/nav.dart';
import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/services/collage_compose.dart';
import 'package:markcut/services/collage_pack.dart';
import 'package:markcut/services/draft_assets.dart';

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

/// 畫面上的方塊清單（就是畫面 state 裡那一份，物件本人）
List<CollageFreeItem> _items(WidgetTester t) => _peek(t).layout.items;

/// 每一塊現在的方塊（照物件本人記：複製出來的兩塊是同一張照片）
Map<CollageFreeItem, ui.Rect> _snap(WidgetTester t) =>
    Map<CollageFreeItem, ui.Rect>.identity()
      ..addEntries(_items(t).map((it) => MapEntry(it, it.rect)));

/// 原本那幾塊一塊都沒動（位置、大小一模一樣，也都還在）
void _expectKept(
  WidgetTester t,
  Map<CollageFreeItem, ui.Rect> was,
  String why,
) {
  final now = _items(t);
  for (final e in was.entries) {
    expect(now.any((it) => identical(it, e.key)), isTrue, reason: '$why：少了一塊');
    expect(e.key.rect, e.value, reason: '$why：照片 ${e.key.img} 被動到了');
  }
}

/// 整塊在畫布內
bool _inside(ui.Rect r) =>
    r.left >= -1e-9 &&
    r.top >= -1e-9 &&
    r.right <= 1 + 1e-9 &&
    r.bottom <= 1 + 1e-9;

/// 兩塊疊成一張（中心兩軸都差不到 1%）
bool _stacked(ui.Rect a, ui.Rect b) =>
    (a.center.dx - b.center.dx).abs() < 0.01 &&
    (a.center.dy - b.center.dy).abs() < 0.01;

/// 方塊在畫布上的真實形狀（比例座標要乘回畫布比例）
double _px(ui.Rect r, double canvas) => r.width * canvas / r.height;

double _imgAspect(WidgetTester t, int img) {
  final im = _peek(t).images[img]!;
  return im.width / im.height;
}

/// 自由模式那張畫布的 CustomPaint（painter 是私有的 _FreePainter，靠型別名字找）
final _paint = find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.painter.runtimeType.toString().contains('FreePainter'),
);

/// 畫布在螢幕上的範圍（手勢的座標相對這個框）
Rect _canvas(WidgetTester t) => t.getRect(
  find.ancestor(of: _paint, matching: find.byType(GestureDetector)).first,
);

Rect _onScreen(Rect canvas, ui.Rect r) => Rect.fromLTWH(
  canvas.left + r.left * canvas.width,
  canvas.top + r.top * canvas.height,
  r.width * canvas.width,
  r.height * canvas.height,
);

Offset _at(WidgetTester t, double x, double y) {
  final c = _canvas(t);
  return Offset(c.left + x * c.width, c.top + y * c.height);
}

/// 選取框的四個角點（10px 的白色圓點）
Finder _handles() => find.descendant(
  of: find.ancestor(of: _paint, matching: find.byType(Stack)).first,
  matching: find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.constraints == const BoxConstraints.tightFor(width: 10, height: 10) &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).shape == BoxShape.circle,
  ),
);

/// 選起來的是 [it]：四個角點正好在它的四個角上（角點畫在畫布 1px
/// 的邊框裡面，容許差一點）
void _expectSelected(WidgetTester t, CollageFreeItem it, String why) {
  final h = _handles();
  expect(h, findsNWidgets(4), reason: '$why：要有選取框');
  final r = _onScreen(_canvas(t), it.rect);
  final corners = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight];
  for (var i = 0; i < 4; i++) {
    final c = t.getCenter(h.at(i));
    expect(
      corners.any((k) => (k - c).distance < 2.5),
      isTrue,
      reason: '$why：角點 $c 不在 $r 的角上',
    );
  }
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

/// iPhone 大小的畫面＋假選取器（安卓的系統相片選取器 markcut/pick 回
/// null＝這台沒有，退到 image_picker，跟 collage_free_cap_test 同一套）
_Picker _setUp(WidgetTester t) {
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
  SharedPreferences.setMockInitialValues({});
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
  await t.pump(const Duration(milliseconds: 100));
  expect(_items(t).length, want);
}

/// 點畫布上的一點（比例座標）
Future<void> _tapCanvas(WidgetTester t, double x, double y) async {
  await t.tapAt(_at(t, x, y));
  await t.pump(const Duration(milliseconds: 300));
}

/// 點一塊的中心把它選起來（選到的會被帶到最上層）
Future<void> _select(WidgetTester t, CollageFreeItem it) async {
  await _tapCanvas(t, it.rect.center.dx, it.rect.center.dy);
  expect(identical(_items(t).last, it), isTrue, reason: '點到的要被選起來');
}

/// 畫布比例的膠囊（窄螢幕排不下、會橫捲：先捲進畫面再點）
Future<void> _tapChip(WidgetTester t, String label) async {
  await t.ensureVisible(find.text(label));
  await t.pumpAndSettle();
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

Future<void> _duplicate(WidgetTester t) async {
  final n = _items(t).length;
  await t.tap(find.text('複製'));
  await t.pump();
  expect(_items(t).length, n + 1);
}

/// 單指拖：按下、先走 20px（點擊的門檻一過拖曳就成立，從成立那一刻起算
/// 位移），再走 [delta]
Future<void> _drag(
  WidgetTester t,
  Offset from,
  Offset step,
  Offset delta,
) async {
  final g = await t.createGesture();
  await g.down(from);
  await t.pump();
  await g.moveTo(from + step);
  await t.pump();
  await g.moveTo(from + step + delta);
  await t.pump();
  await g.up();
  await t.pump();
}

/// 自動排版該有的樣子：不重疊、整塊在畫布內、各是照片的形狀；[cover]
/// 給了就再看有沒有塞滿（形狀湊不出畫布比例時本來就置中留邊）
void _expectPacked(WidgetTester t, String why, {double cover = 0}) {
  final rs = [for (final it in _items(t)) it.rect];
  var hit = 0;
  for (var y = 0; y < 100; y++) {
    for (var x = 0; x < 100; x++) {
      final p = ui.Offset((x + 0.5) / 100, (y + 0.5) / 100);
      if (rs.any((r) => r.contains(p))) hit++;
    }
  }
  expect(hit / 10000, greaterThanOrEqualTo(cover), reason: '$why：要塞滿畫布');
  for (var i = 0; i < rs.length; i++) {
    expect(_inside(rs[i]), isTrue, reason: '$why：方塊 $i 出了畫布');
    for (var j = i + 1; j < rs.length; j++) {
      final o = rs[i].intersect(rs[j]);
      if (o.width > 0 && o.height > 0) {
        expect(o.width * o.height, lessThan(1e-6), reason: '$why：方塊不該重疊');
      }
    }
  }
  for (final it in _items(t)) {
    expect(
      _px(it.rect, 1) / _imgAspect(t, it.img),
      closeTo(1, kCollagePackMaxStretch),
      reason: '$why：照片 ${it.img} 的形狀跑掉了',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('排好之後加照片', () {
    testWidgets('拖過、拉過角之後加照片：原本的一塊都不動；新的疊在最上層、在畫布內、選起來', (t) async {
      final picker = await _openFree(t);
      await _addPhotos(
        t,
        picker,
        await _photos(t, [(300, 200), (200, 300), (240, 240)]),
      );

      // 使用者排版：第一塊往畫布中間拖一段（拖＝選起來、帶到最上層）
      final a = _items(t).first;
      final auto = a.rect;
      final cv = _canvas(t);
      final c = _onScreen(cv, a.rect).center;
      await _drag(
        t,
        c,
        const Offset(20, 0),
        Offset(c.dx < cv.center.dx ? 30 : -30, c.dy < cv.center.dy ? 22 : -22),
      );
      expect(a.rect.width, closeTo(auto.width, 1e-9), reason: '拖＝搬，大小不變');
      expect(a.rect.height, closeTo(auto.height, 1e-9));
      expect(a.rect.topLeft, isNot(auto.topLeft), reason: '拖曳要真的搬到');

      // 再拉它朝畫布中間的那個角＝改大小
      final moved = a.rect;
      final r = _onScreen(cv, moved);
      final corner = Offset(
        r.center.dx < cv.center.dx ? r.right : r.left,
        r.center.dy < cv.center.dy ? r.bottom : r.top,
      );
      final inX = r.center.dx < corner.dx ? -1.0 : 1.0;
      final inY = r.center.dy < corner.dy ? -1.0 : 1.0;
      await _drag(t, corner, Offset(20 * inX, 0), Offset(25 * inX, 25 * inY));
      expect(a.rect.size, isNot(moved.size), reason: '拉角要真的改到大小');

      // 加一張：排好的一塊都不動
      final before = _snap(t);
      await _addPhotos(t, picker, await _photos(t, [(300, 200)]));
      _expectKept(t, before, '加一張');
      final one = _items(t).last;
      expect(before.containsKey(one), isFalse, reason: '最上層要是新加的那張');
      expect(one.img, _peek(t).images.length - 1);
      expect(_inside(one.rect), isTrue, reason: '新的整塊在畫布內：${one.rect}');
      final area = one.rect.width * one.rect.height;
      expect(area, inInclusiveRange(0.05, 0.5), reason: '新的不能太小、也不能蓋滿畫布');
      expect(
        math.min(one.rect.width, one.rect.height),
        greaterThanOrEqualTo(kCollageFreeMinSide),
      );
      expect(
        _px(one.rect, 1) / _imgAspect(t, one.img),
        closeTo(1, kCollagePackMaxStretch),
        reason: '新的是照片的形狀',
      );
      _expectSelected(t, one, '加一張');

      // 一次加兩張：彼此不疊、都在畫布內、最後一張選起來；原本的照舊不動
      final before2 = _snap(t);
      await _addPhotos(t, picker, await _photos(t, [(200, 300), (320, 180)]));
      _expectKept(t, before2, '加兩張');
      final two = _items(t).sublist(_items(t).length - 2);
      for (final it in two) {
        expect(before2.containsKey(it), isFalse);
        expect(_inside(it.rect), isTrue, reason: '新的整塊在畫布內：${it.rect}');
        expect(
          math.min(it.rect.width, it.rect.height),
          greaterThanOrEqualTo(kCollageFreeMinSide),
        );
      }
      final o = two[0].rect.intersect(two[1].rect);
      expect(
        o.width <= 0 || o.height <= 0 || o.width * o.height < 1e-9,
        isTrue,
        reason: '同一批新加的不能疊在一起',
      );
      _expectSelected(t, two[1], '加兩張');

      // 再一張一張加：不會剛好疊在前一張新的上面（沒拖開的話往旁邊錯開）
      for (var k = 0; k < 2; k++) {
        final was = _snap(t);
        await _addPhotos(t, picker, await _photos(t, [(300, 200)]));
        _expectKept(t, was, '再加第 ${k + 1} 張');
        final it = _items(t).last;
        expect(_inside(it.rect), isTrue);
        for (final other in was.keys) {
          expect(
            _stacked(it.rect, other.rect),
            isFalse,
            reason: '新加的疊在照片 ${other.img} 正上方：${it.rect} vs ${other.rect}',
          );
        }
        _expectSelected(t, it, '再加第 ${k + 1} 張');
      }
      // 提示不再說「加照片會自動排滿畫布」（排過之後就不是真的）
      expect(find.text('最後選取的照片會在最上層'), findsOneWidget);
      expect(find.text('加照片會自動排滿畫布；最後選取的照片會在最上層'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('雙指縮放過也算排過：加照片不重排', (t) async {
      final picker = await _openFree(t);
      await _addPhotos(t, picker, await _photos(t, [(300, 200), (200, 300)]));
      final a = _items(t).first;
      await _select(t, a);
      final was = a.rect;
      final c = _onScreen(_canvas(t), a.rect).center;
      final f1 = await t.createGesture();
      final f2 = await t.createGesture();
      await f1.down(c - const Offset(30, 0));
      await t.pump();
      await f2.down(c + const Offset(30, 0));
      await t.pump();
      for (var i = 1; i <= 4; i++) {
        await f1.moveTo(c - Offset(30.0 - 4 * i, 0));
        await f2.moveTo(c + Offset(30.0 - 4 * i, 0));
        await t.pump();
      }
      await f1.up();
      await f2.up();
      await t.pump();
      expect(a.rect.width, lessThan(was.width), reason: '捏合要真的縮到');

      final before = _snap(t);
      await _addPhotos(t, picker, await _photos(t, [(240, 240)]));
      _expectKept(t, before, '縮放過再加');
      expect(_inside(_items(t).last.rect), isTrue);
      expect(t.takeException(), isNull);
    });

    testWidgets('還沒動過（只點選過、按過隨機排列）：加照片照舊連同原本的一起自動重排', (t) async {
      final picker = await _openFree(t);
      await _addPhotos(
        t,
        picker,
        await _photos(t, [(300, 200), (200, 300), (240, 240)]),
      );
      _expectPacked(t, '三張');
      await t.tap(find.text('隨機排列'));
      await t.pumpAndSettle();
      _expectPacked(t, '隨機排列');
      // 點選會換疊放順序但不動方塊：還是算沒動過
      await _select(t, _items(t).first);
      final before = _snap(t);

      await _addPhotos(t, picker, await _photos(t, [(320, 180), (180, 320)]));
      _expectPacked(t, '再加兩張');
      expect(
        before.entries.any((e) => e.key.rect != e.value),
        isTrue,
        reason: '沒動過的排法要連同新的一起重排',
      );
      _expectSelected(t, _items(t).last, '重排後最後加的那張');
      expect(t.takeException(), isNull);
    });
  });

  group('複製', () {
    testWidgets('同一張、同樣的裁切與大小，錯開一點、在畫布內、最上層、選起來；之後加照片不重排', (t) async {
      final picker = await _openFree(t);
      await _addPhotos(t, picker, await _photos(t, [(300, 200), (200, 300)]));
      // 剛加的那張是選起來的：「複製」跟著出現；點畫布外的黑邊取消選取就收掉
      expect(find.text('複製'), findsOneWidget);
      await t.tapAt(_canvas(t).topLeft - const Offset(8, 8));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('複製'), findsNothing, reason: '沒選照片不出現');
      final src = _items(t).first;
      await _select(t, src);
      expect(find.text('複製'), findsOneWidget);
      final before = _snap(t);

      await _duplicate(t);
      final dup = _items(t).last;
      expect(identical(dup, src), isFalse);
      expect(dup.img, src.img, reason: '同一張照片');
      expect(dup.crop, src.crop);
      expect(dup.rect.width, closeTo(src.rect.width, 1e-12));
      expect(dup.rect.height, closeTo(src.rect.height, 1e-12));
      final d = dup.rect.center - src.rect.center;
      final off = math.max(d.dx.abs(), d.dy.abs());
      expect(off, inInclusiveRange(0.02, 0.1), reason: '錯開一點：$d');
      expect(_inside(dup.rect), isTrue, reason: '複製出來的在畫布內：${dup.rect}');
      _expectKept(t, before, '複製');
      _expectSelected(t, dup, '複製');
      expect(_peek(t).images.length, 2, reason: '照片不另解一份');

      // 複製＝自己在排：之後加照片不重排
      final before2 = _snap(t);
      await _addPhotos(t, picker, await _photos(t, [(240, 240)]));
      _expectKept(t, before2, '複製後加照片');
      expect(t.takeException(), isNull);
    });

    testWidgets('貼著右下角的往左上錯；同一張連複製兩次不疊在一起；跟畫布一樣大的只出血一步', (t) async {
      final picker = await _openFree(t);
      await _addPhotos(t, picker, await _photos(t, [(240, 240)]));
      final src = _items(t).single;
      // 擺到右下角（測試鉤子給的是畫面上那一份本人）
      src.rect = const ui.Rect.fromLTWH(0.6, 0.6, 0.4, 0.4);
      await t.pump();
      await _select(t, src);
      await _duplicate(t);
      final d1 = _items(t).last;
      expect(d1.rect.left, closeTo(0.56, 1e-9), reason: '右邊沒地方了往左錯');
      expect(d1.rect.top, closeTo(0.56, 1e-9), reason: '下面沒地方了往上錯');
      expect(_inside(d1.rect), isTrue);

      // 再選原本那張（只有它蓋到的右下角）、再複製一次：不疊在第一份上
      await _tapCanvas(t, 0.985, 0.985);
      expect(identical(_items(t).last, src), isTrue);
      await _duplicate(t);
      final d2 = _items(t).last;
      expect(_inside(d2.rect), isTrue);
      for (final other in [src, d1]) {
        expect(
          _stacked(d2.rect, other.rect),
          isFalse,
          reason: '第二份疊在 ${other.rect} 上：${d2.rect}',
        );
      }
      _expectSelected(t, d2, '第二份');

      // 跟畫布一樣大：哪一軸都沒地方錯開，只好出血一步（中心還在畫布裡），
      // 不然複製出來的完全疊在原處，看起來像按了沒反應
      src.rect = const ui.Rect.fromLTWH(0, 0, 1, 1);
      await t.pump();
      await _tapCanvas(t, 0.1, 0.1);
      expect(identical(_items(t).last, src), isTrue);
      await _duplicate(t);
      final d3 = _items(t).last;
      expect(d3.rect.left, closeTo(0.04, 1e-9));
      expect(d3.rect.top, closeTo(0.04, 1e-9));
      expect(d3.rect.width, closeTo(1, 1e-9));
      expect(d3.rect.height, closeTo(1, 1e-9));
      expect(d3.rect.center.dx, inInclusiveRange(0, 1));
      expect(d3.rect.center.dy, inInclusiveRange(0, 1));
      expect(t.takeException(), isNull);
    });

    testWidgets('換畫布比例：原本那張跟複製的各走各的，不會被搬到同一處；切回來一模一樣', (t) async {
      final picker = await _openFree(t);
      await _addPhotos(t, picker, await _photos(t, [(300, 200), (200, 300)]));
      final src = _items(t).first;
      await _select(t, src);
      await _duplicate(t);
      final dup = _items(t).last;
      final on11 = _snap(t);

      await _tapChip(t, '16:9');
      await t.pumpAndSettle();
      expect(_peek(t).layout.canvasAspect, closeTo(16 / 9, 1e-9));
      expect(
        _stacked(src.rect, dup.rect),
        isFalse,
        reason: '兩塊被搬到同一處：${src.rect} vs ${dup.rect}',
      );
      for (final e in on11.entries) {
        expect(
          _px(e.key.rect, 16 / 9) / _px(e.value, 1),
          closeTo(1, 1e-6),
          reason: '照片 ${e.key.img} 的形狀變了',
        );
      }

      await _tapChip(t, '1:1');
      await t.pumpAndSettle();
      for (final e in on11.entries) {
        final r = e.key.rect;
        expect(r.left, closeTo(e.value.left, 1e-9));
        expect(r.top, closeTo(e.value.top, 1e-9));
        expect(r.width, closeTo(e.value.width, 1e-9));
        expect(r.height, closeTo(e.value.height, 1e-9));
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('宮格模式選了格子只有裁切，沒有複製', (t) async {
      SharedPreferences.setMockInitialValues({});
      _setUp(t);
      await t.pumpWidget(
        MaterialApp(
          home: CollageScreen(
            photos: await _photos(t, [(300, 200), (200, 300)]),
          ),
        ),
      );
      await _waitLoaded(t);
      final cell = find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_CellPainter',
      );
      await t.tap(cell.first);
      await t.pump();
      expect(find.text('裁切'), findsOneWidget);
      expect(find.text('複製'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('草稿', () {
    late Directory root;
    late String path;

    setUp(() {
      root = Directory.systemTemp.createTempSync('collage_keep_');
      DraftAssets.supportDirOverride = Directory('${root.path}/support')
        ..createSync();
      DraftAssets.pickerRootsOverride = [];
    });

    tearDown(() {
      DraftAssets.supportDirOverride = null;
      DraftAssets.pickerRootsOverride = null;
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 一張 80×40 的照片存成檔案（左半紅、右半藍）
    Future<void> writePhoto(WidgetTester t) async {
      await t.runAsync(() async {
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        c.drawRect(
          const Rect.fromLTWH(0, 0, 40, 40),
          Paint()..color = const Color(0xFFFF0000),
        );
        c.drawRect(
          const Rect.fromLTWH(40, 0, 40, 40),
          Paint()..color = const Color(0xFF0000FF),
        );
        final img = await rec.endRecording().toImage(80, 40);
        final d = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        path = '${root.path}${Platform.pathSeparator}photo.png';
        File(path).writeAsBytesSync(d!.buffer.asUint8List());
      });
    }

    Future<void> waitFor(WidgetTester t, bool Function() ready) async {
      for (var i = 0; i < 150 && !ready(); i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await t.pump(const Duration(milliseconds: 30));
      }
      expect(ready(), isTrue, reason: '等不到畫面');
      await t.pump(const Duration(milliseconds: 300));
    }

    /// 從假首頁把拼圖頁 push 出去（離開保護要能真的 pop 回來）
    Future<void> open(WidgetTester t, Map<String, dynamic> draft) async {
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  editRoute(builder: (_) => CollageScreen(restore: draft)),
                ),
                child: const Text('首頁'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('首頁'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await waitFor(
        t,
        () =>
            find.byType(CollageScreen).evaluate().isNotEmpty &&
            _peek(t).images.isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
    }

    const rightHalf = Rect.fromLTWH(0.5, 0, 0.5, 1);

    testWidgets('兩塊指著同一張照片：存草稿、續作回來還是兩塊、同一張圖、位置與裁切都在', (t) async {
      SharedPreferences.setMockInitialValues({});
      _setUp(t);
      await writePhoto(t);
      await open(t, {
        'photos': [path],
        'free': true,
        'cols': 1,
        'rows': 1,
        'aspect': 1.0,
        'order': [0],
        'freeItems': [
          {
            'img': 0,
            'l': 0.1,
            't': 0.2,
            'w': 0.4,
            'h': 0.4,
            'crop': collageCropToJson(rightHalf),
          },
        ],
      });
      final src = _items(t).single;
      expect(src.crop, rightHalf);
      await _select(t, src);
      await _duplicate(t);
      final dup = _items(t).last;
      expect(dup.img, src.img);
      expect(dup.crop, rightHalf, reason: '裁切跟著複製');
      final rects = [for (final it in _items(t)) it.rect];

      // 返回 → 保留草稿
      unawaited(t.state<NavigatorState>(find.byType(Navigator)).maybePop());
      await t.pumpAndSettle();
      await t.tap(find.text('保留草稿'));
      await waitFor(t, () => find.byType(CollageScreen).evaluate().isEmpty);
      final raw = (await SharedPreferences.getInstance()).getString(
        kCollageDraftKey,
      )!;
      final draft = jsonDecode(raw) as Map<String, dynamic>;
      expect((draft['photos'] as List).length, 1, reason: '照片只記一份');
      final rows = (draft['freeItems'] as List).cast<Map>();
      expect(rows.length, 2);
      for (var i = 0; i < 2; i++) {
        expect(rows[i]['img'], 0, reason: '兩塊都指著同一張');
        expect(rows[i]['crop'], [0.5, 0.0, 0.5, 1.0]);
        expect((rows[i]['l'] as num).toDouble(), closeTo(rects[i].left, 1e-12));
        expect((rows[i]['t'] as num).toDouble(), closeTo(rects[i].top, 1e-12));
        expect(
          (rows[i]['w'] as num).toDouble(),
          closeTo(rects[i].width, 1e-12),
        );
        expect(
          (rows[i]['h'] as num).toDouble(),
          closeTo(rects[i].height, 1e-12),
        );
      }
      expect(draft['freeAuto'], isFalse, reason: '有複製＝使用者排的');

      // 續作：兩塊回來、同一張圖（只解一張）、位置與裁切照舊
      await t.pumpWidget(const SizedBox());
      await open(t, draft);
      final items = _items(t);
      expect(items.length, 2);
      expect(items[0].img, items[1].img);
      expect(_peek(t).images.whereType<ui.Image>().length, 1);
      for (var i = 0; i < 2; i++) {
        expect(items[i].crop, rightHalf);
        expect(items[i].rect.left, closeTo(rects[i].left, 1e-12));
        expect(items[i].rect.top, closeTo(rects[i].top, 1e-12));
        expect(items[i].rect.width, closeTo(rects[i].width, 1e-12));
        expect(items[i].rect.height, closeTo(rects[i].height, 1e-12));
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
    });

    for (final auto in [false, true]) {
      testWidgets(auto ? '續作的草稿當初是自動排的：加照片照舊自動重排' : '續作的草稿當初是使用者排的：加照片不重排', (
        t,
      ) async {
        SharedPreferences.setMockInitialValues({});
        final picker = _setUp(t);
        await writePhoto(t);
        await open(t, {
          'photos': [path, path],
          'free': true,
          'cols': 2,
          'rows': 1,
          'aspect': 1.0,
          'order': [0, 1],
          'freeItems': [
            {'img': 0, 'l': 0.05, 't': 0.1, 'w': 0.5, 'h': 0.25},
            {'img': 1, 'l': 0.3, 't': 0.5, 'w': 0.6, 'h': 0.3},
          ],
          if (auto) 'freeAuto': true,
        });
        final before = _snap(t);
        await _addPhotos(t, picker, await _photos(t, [(240, 240)]));
        if (auto) {
          expect(
            before.entries.any((e) => e.key.rect != e.value),
            isTrue,
            reason: '自動排的要連同新的一起重排',
          );
          _expectPacked(t, '續作後加照片');
        } else {
          _expectKept(t, before, '續作後加照片');
          expect(_inside(_items(t).last.rect), isTrue);
        }
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
      });
    }
  });
}
