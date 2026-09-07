// 自由組圖的雙指縮放。
//
// 測試回報（iOS TestFlight）：「自由組圖不能雙手縮放」——模式切到「自由」、
// 點一張照片選起來（琥珀框＋四個角），兩指在照片上張開／捏合完全沒反應。
// 這裡釘住：兩指張開＝照片等比放大（比例不變、繞著兩指中點）、捏合＝縮小
// （不小於抓得到的最小邊）、兩指一起移＝搬；第二指中途才放上來以那一刻
// 重新起手、不跳；放開一指之後另一指接著拖照樣搬、不跳回去；單指拖曳
// 與拉角照舊。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/services/collage_compose.dart';
import 'package:markcut/widgets/watermark_layer.dart';

/// 一張單色假照片
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

/// 自由模式那張畫布的 CustomPaint。painter 是私有類別（_FreePainter），
/// 靠型別名字找；它的 items 欄位是公開名字，dynamic 拿得到
final _paint = find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.painter.runtimeType.toString().contains('FreePainter'),
);

/// 畫面上的方塊清單（就是畫面 state 裡那一份；rect 是 0~1 的畫布比例）
List<CollageFreeItem> _items(WidgetTester t) =>
    ((t.widget<CustomPaint>(_paint).painter as dynamic).items as List)
        .cast<CollageFreeItem>();

/// 畫布在螢幕上的範圍。手勢的座標是相對這個框，不是 painter——
/// painter 在 1px 的邊框裡面
Rect _canvas(WidgetTester t) => t.getRect(
  find.ancestor(of: _paint, matching: find.byType(GestureDetector)).first,
);

/// 比例座標的方塊 → 螢幕座標
Rect _onScreen(Rect canvas, Rect r) => Rect.fromLTWH(
  canvas.left + r.left * canvas.width,
  canvas.top + r.top * canvas.height,
  r.width * canvas.width,
  r.height * canvas.height,
);

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

/// 開拼圖頁（兩張照片）、等解碼完、切到自由模式。
/// 預設浮水印先關掉：它蓋在畫布正中央而且是 opaque，手指按到它會被
/// 浮水印圖層整個吃掉（那是另一回事），這裡只測畫布本身的手勢
Future<void> _openFree(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(390, 780));
  addTearDown(() => t.binding.setSurfaceSize(null));
  late Uint8List a, b;
  // 圖片編解碼是真非同步，要包 runAsync 才會完成
  await t.runAsync(() async {
    a = await _png(const Color(0xFFFF0000), 300, 200);
    b = await _png(const Color(0xFF0000FF), 200, 300);
  });
  await t.pumpWidget(
    MaterialApp(
      home: CollageScreen(
        photos: [
          XFile.fromData(a, name: 'a.png', mimeType: 'image/png'),
          XFile.fromData(b, name: 'b.png', mimeType: 'image/png'),
        ],
      ),
    ),
  );
  // 等 _load 讀檔＋解碼完成（輪詢直到轉圈圈消失）
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
  final wm = t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).settings;
  wm.text.enabled = false;
  wm.logo.enabled = false;
  await t.tap(find.text('自由'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  expect(_paint, findsOneWidget);
  expect(_items(t), isNotEmpty);
}

/// 兩根手指：從 a0／b0 按下，分幾步移到 a1／b1，再放開
/// （跟裁切畫面的雙指測試同一個寫法）
Future<void> _pinch(
  WidgetTester t, {
  required Offset a0,
  required Offset a1,
  required Offset b0,
  required Offset b1,
  int steps = 6,
}) async {
  final a = await t.createGesture(pointer: 11);
  final b = await t.createGesture(pointer: 12);
  await a.down(a0);
  await t.pump();
  await b.down(b0);
  await t.pump();
  for (var i = 1; i <= steps; i++) {
    final k = i / steps;
    await a.moveTo(Offset.lerp(a0, a1, k)!);
    await b.moveTo(Offset.lerp(b0, b1, k)!);
    await t.pump();
  }
  await a.up();
  await b.up();
  await t.pump();
}

/// 單指拖曳：先走 40px 讓拖曳成立（超過 pan 的 36px 門檻），再走 [delta]。
/// GestureDetector 的拖曳是「成立那一刻」起算（DragStartBehavior.start），
/// 所以成立前走的那段不算位移——測試回報的期望值只看 [delta]
Future<void> _drag(WidgetTester t, Offset from, Offset delta) async {
  final g = await t.createGesture(pointer: 21);
  await g.down(from);
  await t.pump();
  await g.moveTo(from + const Offset(40, 0));
  await t.pump();
  await g.moveTo(from + const Offset(40, 0) + delta);
  await t.pump();
  await g.up();
  await t.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 選取的那一張：點選會把它搬到最上層（清單最後），所以用照片索引追
  CollageFreeItem byImg(WidgetTester t, int img) =>
      _items(t).firstWhere((it) => it.img == img);

  /// 點第一張照片把它選起來（琥珀框＋四角），回傳它的照片索引
  Future<int> selectFirst(WidgetTester t) async {
    final img = _items(t).first.img;
    final c = _onScreen(_canvas(t), byImg(t, img).rect).center;
    await t.tapAt(c);
    await t.pump();
    expect(_handles(), findsNWidgets(4), reason: '選中的照片要有四個角');
    return img;
  }

  group('雙指的數學（collagePinchFreeRect）', () {
    const start = Rect.fromLTWH(0.1, 0.2, 0.4, 0.3);

    test('兩指距離變幾倍方塊就變幾倍，寬高同乘（比例不變），繞著焦點', () {
      // 焦點在方塊裡的相對位置 (1/4, 1/3)，縮完還在焦點底下
      final r = collagePinchFreeRect(
        start: start,
        scale: 1.5,
        focal: const Offset(0.2, 0.3),
        pan: Offset.zero,
      );
      expect(r.width, closeTo(0.6, 1e-12));
      expect(r.height, closeTo(0.45, 1e-12));
      expect(r.left + r.width / 4, closeTo(0.2, 1e-12));
      expect(r.top + r.height / 3, closeTo(0.3, 1e-12));
    });

    test('兩指中點移了就搬，大小不變', () {
      final r = collagePinchFreeRect(
        start: start,
        scale: 1,
        focal: start.center,
        pan: const Offset(0.05, -0.1),
      );
      expect(r.width, closeTo(0.4, 1e-12));
      expect(r.height, closeTo(0.3, 1e-12));
      expect(r.left, closeTo(0.15, 1e-12));
      expect(r.top, closeTo(0.1, 1e-12));
    });

    test('捏到底：短邊停在最小邊、比例不破；拉到底：長邊停在畫布兩倍', () {
      final small = collagePinchFreeRect(
        start: start,
        scale: 0.001,
        focal: start.center,
        pan: Offset.zero,
      );
      expect(small.height, closeTo(kCollageFreeMinSide, 1e-12));
      expect(small.width, closeTo(0.4 * kCollageFreeMinSide / 0.3, 1e-12));
      final big = collagePinchFreeRect(
        start: start,
        scale: 100,
        focal: start.center,
        pan: Offset.zero,
      );
      expect(big.width, closeTo(2.0, 1e-12));
      expect(big.height, closeTo(1.5, 1e-12));
    });

    test('中心不出畫布：怎麼推，方塊的中心都夾在 0~1（大小不變）', () {
      final r = collagePinchFreeRect(
        start: start,
        scale: 1,
        focal: start.center,
        pan: const Offset(-5, 7),
      );
      expect(r.center.dx, closeTo(0, 1e-12));
      expect(r.center.dy, closeTo(1, 1e-12));
      expect(r.width, closeTo(0.4, 1e-12));
      expect(r.height, closeTo(0.3, 1e-12));
    });

    test('亂拉 5000 次的不變量：比例不變、邊在極限內、中心在畫布內', () {
      final rnd = math.Random(7);
      for (var i = 0; i < 5000; i++) {
        final w = kCollageFreeMinSide + rnd.nextDouble() * 1.9;
        final h = kCollageFreeMinSide + rnd.nextDouble() * 1.9;
        final s = Rect.fromLTWH(
          rnd.nextDouble() * 2 - 1,
          rnd.nextDouble() * 2 - 1,
          w,
          h,
        );
        final r = collagePinchFreeRect(
          start: s,
          scale: 0.01 + rnd.nextDouble() * 20,
          focal: Offset(
            s.left + rnd.nextDouble() * w,
            s.top + rnd.nextDouble() * h,
          ),
          pan: Offset(rnd.nextDouble() * 4 - 2, rnd.nextDouble() * 4 - 2),
        );
        expect(r.width / r.height, closeTo(w / h, 1e-9));
        expect(r.width, greaterThanOrEqualTo(kCollageFreeMinSide - 1e-9));
        expect(r.height, greaterThanOrEqualTo(kCollageFreeMinSide - 1e-9));
        expect(r.width, lessThanOrEqualTo(2 + 1e-9));
        expect(r.height, lessThanOrEqualTo(2 + 1e-9));
        expect(r.center.dx, inInclusiveRange(-1e-9, 1 + 1e-9));
        expect(r.center.dy, inInclusiveRange(-1e-9, 1 + 1e-9));
      }
    });
  });

  group('自由模式的雙指', () {
    testWidgets('兩指張開：照片等比放大、繞著兩指中點，比例不變', (t) async {
      await _openFree(t);
      final img = await selectFirst(t);
      final before = byImg(t, img).rect;
      final canvas = _canvas(t);
      final c = _onScreen(canvas, before).center;
      // 兩指擺在同一條水平線上，距離 80 → 120（1.5 倍），中點不動
      await _pinch(
        t,
        a0: c + const Offset(-40, 0),
        a1: c + const Offset(-60, 0),
        b0: c + const Offset(40, 0),
        b1: c + const Offset(60, 0),
      );
      final after = byImg(t, img).rect;
      // 每邊最多畫布的兩倍（跟拉角一樣），碰到上限就停在那
      final k = math.min(1.5, math.min(2 / before.width, 2 / before.height));
      expect(after.width, closeTo(before.width * k, 1e-6));
      expect(after.height, closeTo(before.height * k, 1e-6));
      expect(
        after.width / after.height,
        closeTo(before.width / before.height, 1e-9),
      );
      expect(after.center.dx, closeTo(before.center.dx, 1e-6));
      expect(after.center.dy, closeTo(before.center.dy, 1e-6));
      expect(_handles(), findsNWidgets(4), reason: '縮放完仍是選取中');
      expect(t.takeException(), isNull);
    });

    testWidgets('捏合：縮小；捏到底短邊停在最小邊，比例不破', (t) async {
      await _openFree(t);
      final img = await selectFirst(t);
      final before = byImg(t, img).rect;
      final c = _onScreen(_canvas(t), before).center;
      await _pinch(
        t,
        a0: c + const Offset(-60, -20),
        a1: c + const Offset(-1, 0),
        b0: c + const Offset(60, 20),
        b1: c + const Offset(1, 0),
        steps: 10,
      );
      final after = byImg(t, img).rect;
      expect(after.width, lessThan(before.width));
      expect(after.height, lessThan(before.height));
      // 最小邊 0.08 ＝ 手指的大小，跟拉角同一個下限
      expect(math.min(after.width, after.height), closeTo(0.08, 1e-6));
      expect(
        after.width / after.height,
        closeTo(before.width / before.height, 1e-9),
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('兩指一起移＝搬，大小不變；放開一指之後另一指接著拖，不跳回去', (t) async {
      await _openFree(t);
      final img = await selectFirst(t);
      final before = byImg(t, img).rect;
      final canvas = _canvas(t);
      final c = _onScreen(canvas, before).center;
      final a = await t.createGesture(pointer: 11);
      final b = await t.createGesture(pointer: 12);
      final a0 = c + const Offset(-40, -20);
      final b0 = c + const Offset(40, 20);
      await a.down(a0);
      await t.pump();
      await b.down(b0);
      await t.pump();
      const shift = Offset(15, -25);
      for (var i = 1; i <= 5; i++) {
        await a.moveTo(a0 + shift * (i / 5));
        await b.moveTo(b0 + shift * (i / 5));
        await t.pump();
      }
      final moved = byImg(t, img).rect;
      expect(moved.width, closeTo(before.width, 1e-9));
      expect(moved.height, closeTo(before.height, 1e-9));
      expect(moved.left, closeTo(before.left + shift.dx / canvas.width, 1e-6));
      expect(moved.top, closeTo(before.top + shift.dy / canvas.height, 1e-6));
      // 放開 a，b 接著拖：從放開那一刻的位置起算，大小不變、不跳
      await a.up();
      await t.pump();
      const more = Offset(10, 12);
      await b.moveTo(b0 + shift + more);
      await t.pump();
      final dragged = byImg(t, img).rect;
      expect(dragged.width, closeTo(before.width, 1e-9));
      expect(dragged.height, closeTo(before.height, 1e-9));
      expect(dragged.left, closeTo(moved.left + more.dx / canvas.width, 1e-6));
      expect(dragged.top, closeTo(moved.top + more.dy / canvas.height, 1e-6));
      await b.up();
      await t.pump();
      expect(byImg(t, img).rect, dragged);
      expect(t.takeException(), isNull);
    });

    testWidgets('第二指中途才放上來：以那一刻的方塊重新起手，繞著兩指中點放大，不跳', (t) async {
      await _openFree(t);
      final img = await selectFirst(t);
      final before = byImg(t, img).rect;
      final canvas = _canvas(t);
      final c = _onScreen(canvas, before).center;
      final a = await t.createGesture(pointer: 11);
      final b = await t.createGesture(pointer: 12);
      // 一指先搬：40px 成立、再走 10px
      await a.down(c);
      await t.pump();
      await a.moveTo(c + const Offset(40, 0));
      await t.pump();
      await a.moveTo(c + const Offset(50, 0));
      await t.pump();
      final shifted = byImg(t, img).rect;
      expect(shifted.left, closeTo(before.left + 10 / canvas.width, 1e-6));
      expect(shifted.width, closeTo(before.width, 1e-9));
      // 第二指放上來（距離 60），兩指水平拉開到 90（1.5 倍），中點不動
      final a0 = c + const Offset(50, 0);
      final b0 = c + const Offset(-10, 0);
      await b.down(b0);
      await t.pump();
      final mid = (a0 + b0) / 2;
      // 焦點在起手方塊裡的相對位置
      final relX = (mid.dx - canvas.left) / canvas.width;
      final relY = (mid.dy - canvas.top) / canvas.height;
      final fx = (relX - shifted.left) / shifted.width;
      final fy = (relY - shifted.top) / shifted.height;
      for (var i = 1; i <= 5; i++) {
        await a.moveTo(a0 + Offset(3.0 * i, 0));
        await b.moveTo(b0 + Offset(-3.0 * i, 0));
        await t.pump();
        final k = (60 + 6.0 * i) / 60;
        final now = byImg(t, img).rect;
        // 一路上每一步都是「搬完的方塊 × 目前的倍率」，沒有跳
        expect(now.width, closeTo(shifted.width * k, 1e-6));
        expect(now.height, closeTo(shifted.height * k, 1e-6));
        // 焦點底下那塊內容留在指尖底下
        expect((relX - now.left) / now.width, closeTo(fx, 1e-6));
        expect((relY - now.top) / now.height, closeTo(fy, 1e-6));
      }
      await a.up();
      await b.up();
      await t.pump();
      expect(t.takeException(), isNull);
    });
  });

  group('單指照舊', () {
    testWidgets('框裡拖＝搬整塊、拖角＝改大小', (t) async {
      await _openFree(t);
      final img = await selectFirst(t);
      final before = byImg(t, img).rect;
      final canvas = _canvas(t);
      // 位移挑得離畫布邊、中線、隔壁照片的邊都超過 8px 的吸附半徑
      await _drag(t, _onScreen(canvas, before).center, const Offset(20, 15));
      final moved = byImg(t, img).rect;
      expect(moved.width, closeTo(before.width, 1e-9));
      expect(moved.height, closeTo(before.height, 1e-9));
      expect(moved.left, closeTo(before.left + 20 / canvas.width, 1e-6));
      expect(moved.top, closeTo(before.top + 15 / canvas.height, 1e-6));
      // 拉左上角：對角不動。角的觸控範圍 24px，成立那一刻（走 20px）
      // 還在範圍內才算拉角，所以這裡自己走：20 成立、再走 (30, 20)
      final corner = _onScreen(canvas, moved).topLeft;
      final g = await t.createGesture(pointer: 22);
      await g.down(corner);
      await t.pump();
      await g.moveTo(corner + const Offset(20, 0));
      await t.pump();
      await g.moveTo(corner + const Offset(50, 20));
      await t.pump();
      await g.up();
      await t.pump();
      final resized = byImg(t, img).rect;
      expect(resized.left, closeTo(moved.left + 30 / canvas.width, 1e-6));
      expect(resized.top, closeTo(moved.top + 20 / canvas.height, 1e-6));
      expect(resized.right, closeTo(moved.right, 1e-9));
      expect(resized.bottom, closeTo(moved.bottom, 1e-9));
      expect(t.takeException(), isNull);
    });
  });
}
