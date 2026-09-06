// 裁切框的雙指縮放。
//
// 使用者回報：裁切畫面「自由」模式下兩指縮放不夠自由直覺，「好像雙手會
// 固定比例」——兩指斜著拉，框只會等比放大，沒辦法一邊拉長一邊壓扁。
// 這裡釘住：自由模式兩指水平拉開只變寬、垂直拉開只變高、斜拉兩軸各自
// 照手指走（每條邊跟著同一側的手指走同樣的距離）；鎖比例照舊等比、繞著
// 兩指中點；框不出圖、不小於最小邊、不反轉；單指拖角／搬整塊照舊。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/crop_screen.dart';
import 'package:markcut/services/crop_math.dart';
import 'package:markcut/theme.dart';

/// 一張有構圖的假照片（跟 golden 用的同一張）
Future<Uint8List> _fakePhoto(int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF3A5A8C),
  );
  canvas.drawCircle(
    Offset(w * 0.5, h * 0.42),
    w * 0.22,
    Paint()..color = const Color(0xFFE8C36B),
  );
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// 裁切那一張 CustomPaint（.last 會抓到比例膠囊的水波紋，跟 golden 同一招）
final _paint = find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.painter.runtimeType.toString().contains('CropPainter'),
);

/// 畫面上的幾何：圖片佔的範圍 view、裁切框 crop。painter 是私有類別，
/// 但這兩個欄位是公開名字，dynamic 拿得到。painter 畫的是自己的局部
/// 座標，這裡換成全域座標（上面還有 AppBar），手指才按得準
(Rect, Rect) _geometry(WidgetTester t) {
  final p = t.widget<CustomPaint>(_paint).painter as dynamic;
  final origin = t.getTopLeft(_paint);
  return ((p.view as Rect).shift(origin), (p.crop as Rect).shift(origin));
}

/// 開裁切畫面（rectOnly：按完成回傳 0~1 的框），等圖片解碼完。
/// 回傳的 Future 在按完成之後才會有值
Future<Future<Rect?>> _open(
  WidgetTester t,
  Uint8List bytes, {
  Rect? initial,
}) async {
  await t.binding.setSurfaceSize(const Size(390, 780));
  addTearDown(() => t.binding.setSurfaceSize(null));
  Future<Rect?>? popped;
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      home: Builder(
        builder: (ctx) => Center(
          child: TextButton(
            onPressed: () =>
                popped = pickCropRect(ctx, bytes, initial: initial),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  // 解碼是真的非同步工作，widget test 要 runAsync 才跑得完
  for (var i = 0; i < 60 && _paint.evaluate().isEmpty; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump();
  }
  expect(_paint, findsOneWidget);
  return popped!;
}

/// 兩根手指：從 a0／b0 按下，分幾步移到 a1／b1，再放開
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

void main() {
  late Uint8List photo;
  const half = Rect.fromLTWH(0.25, 0.25, 0.5, 0.5);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  Future<void> loadPhoto(WidgetTester t) async {
    photo = (await t.runAsync(() => _fakePhoto(900, 1200)))!;
  }

  group('雙指的數學（crop_math）', () {
    const view = Rect.fromLTWH(0, 0, 600, 800);
    const start = Rect.fromLTWH(100, 100, 200, 300);
    const minSide = 32.0;
    Rect between(Offset a, Offset b) => Rect.fromPoints(a, b);

    test('自由：每條邊跟著同一側的手指走同樣的距離', () {
      final r = pinchCropFree(
        start: start,
        view: view,
        minSide: minSide,
        fingersStart: between(const Offset(150, 150), const Offset(250, 250)),
        fingers: between(const Offset(120, 160), const Offset(300, 240)),
      );
      expect(r.left, closeTo(100 - 30, 1e-9));
      expect(r.top, closeTo(100 + 10, 1e-9));
      expect(r.right, closeTo(300 + 50, 1e-9));
      expect(r.bottom, closeTo(400 - 10, 1e-9));
    });

    test('自由：兩指擺得完全水平（垂直距離 0）照樣只變寬', () {
      // 用比例算的話這個情況根本算不出垂直的倍率（0 除 0）
      final r = pinchCropFree(
        start: start,
        view: view,
        minSide: minSide,
        fingersStart: between(const Offset(150, 200), const Offset(250, 200)),
        fingers: between(const Offset(110, 200), const Offset(270, 200)),
      );
      expect(r.left, closeTo(60, 1e-9));
      expect(r.right, closeTo(320, 1e-9));
      expect(r.top, 100);
      expect(r.bottom, 400);
    });

    test('自由：手指抖幾個像素，框也只動幾個像素，不會被放大', () {
      // 兩指近乎水平：垂直距離 4，抖到 12。用比例算高會直接變 3 倍
      final r = pinchCropFree(
        start: start,
        view: view,
        minSide: minSide,
        fingersStart: between(const Offset(150, 198), const Offset(250, 202)),
        fingers: between(const Offset(150, 194), const Offset(250, 206)),
      );
      expect(r.width, closeTo(200, 1e-9));
      expect(r.height, closeTo(308, 1e-9));
    });

    test('自由：捏過頭停在最小邊、拉過頭停在圖邊，永遠不反轉', () {
      final small = pinchCropFree(
        start: start,
        view: view,
        minSide: minSide,
        fingersStart: between(Offset.zero, const Offset(500, 700)),
        fingers: between(const Offset(200, 300), const Offset(201, 301)),
      );
      expect(small.width, minSide);
      expect(small.height, minSide);
      // 中心跟著兩指的中點走：中點 (250,350)→(200.5,300.5)，
      // 框的中心 (200,250) 就到 (150.5,200.5)
      expect(small.center.dx, closeTo(150.5, 1e-9));
      expect(small.center.dy, closeTo(200.5, 1e-9));
      final big = pinchCropFree(
        start: start,
        view: view,
        minSide: minSide,
        fingersStart: between(const Offset(150, 150), const Offset(250, 250)),
        fingers: between(const Offset(-900, -900), const Offset(900, 900)),
      );
      expect(big, view);
    });

    test('自由：亂拉 5000 次，框永遠在圖裡、不小於最小邊、不反轉', () {
      final rnd = math.Random(5);
      Offset anywhere() =>
          Offset(rnd.nextDouble() * 1400 - 400, rnd.nextDouble() * 1600 - 400);
      for (var i = 0; i < 5000; i++) {
        final vw = 40 + rnd.nextDouble() * 800;
        final vh = 40 + rnd.nextDouble() * 800;
        final v = Rect.fromLTWH(
          rnd.nextDouble() * 50,
          rnd.nextDouble() * 50,
          vw,
          vh,
        );
        final sw = minSide + rnd.nextDouble() * (vw - minSide);
        final sh = minSide + rnd.nextDouble() * (vh - minSide);
        final s = Rect.fromLTWH(
          v.left + rnd.nextDouble() * (vw - sw),
          v.top + rnd.nextDouble() * (vh - sh),
          sw,
          sh,
        );
        final r = pinchCropFree(
          start: s,
          view: v,
          minSide: minSide,
          fingersStart: between(anywhere(), anywhere()),
          fingers: between(anywhere(), anywhere()),
        );
        expect(r.width, greaterThanOrEqualTo(minSide - 1e-9));
        expect(r.height, greaterThanOrEqualTo(minSide - 1e-9));
        expect(r.left, greaterThanOrEqualTo(v.left - 1e-9));
        expect(r.top, greaterThanOrEqualTo(v.top - 1e-9));
        expect(r.right, lessThanOrEqualTo(v.right + 1e-9));
        expect(r.bottom, lessThanOrEqualTo(v.bottom + 1e-9));
      }
    });

    test('等比（鎖比例）：怎麼拉都是那個比例，繞著焦點', () {
      final r = pinchCropUniform(
        start: const Rect.fromLTWH(100, 100, 160, 90),
        view: view,
        minSide: minSide,
        ratio: 16 / 9,
        scale: 1.5,
        focal: const Offset(140, 130),
        pan: Offset.zero,
      );
      expect(r.width / r.height, closeTo(16 / 9, 1e-9));
      expect(r.width, closeTo(240, 1e-9));
      // 焦點在起手框裡的相對位置 (1/4, 1/3)，縮完還在焦點底下
      expect(r.left + r.width / 4, closeTo(140, 1e-9));
      expect(r.top + r.height / 3, closeTo(130, 1e-9));
    });

    test('等比：捏到底兩邊都不小於最小邊、比例不破；拉到底兩邊都不出圖', () {
      const wide = Rect.fromLTWH(100, 100, 160, 90);
      final small = pinchCropUniform(
        start: wide,
        view: view,
        minSide: minSide,
        ratio: 16 / 9,
        scale: 0.01,
        focal: const Offset(180, 145),
        pan: Offset.zero,
      );
      expect(small.height, closeTo(minSide, 1e-9));
      expect(small.width, closeTo(minSide * 16 / 9, 1e-9));
      final big = pinchCropUniform(
        start: wide,
        view: view,
        minSide: minSide,
        ratio: 16 / 9,
        scale: 100,
        focal: const Offset(180, 145),
        pan: Offset.zero,
      );
      // 圖是 600×800：寬先撞到
      expect(big.width, closeTo(600, 1e-9));
      expect(big.height, closeTo(600 * 9 / 16, 1e-9));
      final tall = pinchCropUniform(
        start: const Rect.fromLTWH(100, 100, 90, 160),
        view: view,
        minSide: minSide,
        ratio: 9 / 16,
        scale: 100,
        focal: const Offset(145, 180),
        pan: Offset.zero,
      );
      expect(tall.height, closeTo(800, 1e-9));
      expect(tall.width, closeTo(450, 1e-9));
    });

    test('等比：亂拉 5000 次的不變量（含自由模式拿不到手指時的退路）', () {
      final rnd = math.Random(9);
      for (var i = 0; i < 5000; i++) {
        final vw = 200 + rnd.nextDouble() * 800;
        final vh = 200 + rnd.nextDouble() * 800;
        final v = Rect.fromLTWH(
          rnd.nextDouble() * 50,
          rnd.nextDouble() * 50,
          vw,
          vh,
        );
        final ratio = rnd.nextBool() ? null : 0.3 + rnd.nextDouble() * 2.7;
        final sw = minSide + rnd.nextDouble() * (vw - minSide);
        final sh = ratio == null
            ? minSide + rnd.nextDouble() * (vh - minSide)
            : math.min(vh, sw / ratio);
        final s = Rect.fromLTWH(
          v.left + rnd.nextDouble() * (vw - sw),
          v.top + rnd.nextDouble() * (vh - sh),
          sw,
          sh,
        );
        final r = pinchCropUniform(
          start: s,
          view: v,
          minSide: minSide,
          ratio: ratio,
          scale: 0.01 + rnd.nextDouble() * 5,
          focal: Offset(
            s.left + rnd.nextDouble() * s.width,
            s.top + rnd.nextDouble() * s.height,
          ),
          pan: Offset(
            rnd.nextDouble() * 800 - 400,
            rnd.nextDouble() * 800 - 400,
          ),
        );
        expect(r.width, greaterThanOrEqualTo(minSide - 1e-9));
        expect(r.height, greaterThanOrEqualTo(minSide - 1e-9));
        expect(r.left, greaterThanOrEqualTo(v.left - 1e-9));
        expect(r.top, greaterThanOrEqualTo(v.top - 1e-9));
        expect(r.right, lessThanOrEqualTo(v.right + 1e-9));
        expect(r.bottom, lessThanOrEqualTo(v.bottom + 1e-9));
        if (ratio != null) {
          expect(r.width / r.height, closeTo(ratio, 1e-9));
        }
      }
    });
  });

  group('自由模式的雙指', () {
    testWidgets('斜拉：每條邊跟著同一側的手指走，不再等比', (t) async {
      await loadPhoto(t);
      final popped = await _open(t, photo, initial: half);
      final (view, before) = _geometry(t);
      final c = before.center;
      // 兩指按在框裡，斜著拉開：水平拉得多（各 30）、垂直拉得少（各 10）
      final a0 = c + const Offset(-40, -30);
      final b0 = c + const Offset(40, 30);
      await _pinch(
        t,
        a0: a0,
        a1: a0 + const Offset(-30, -10),
        b0: b0,
        b1: b0 + const Offset(30, 10),
      );
      final (_, after) = _geometry(t);
      expect(after.left, closeTo(before.left - 30, 0.5));
      expect(after.right, closeTo(before.right + 30, 0.5));
      expect(after.top, closeTo(before.top - 10, 0.5));
      expect(after.bottom, closeTo(before.bottom + 10, 0.5));
      // 所以框的比例變了。以前寬高同乘 scale 一個倍率，比例永遠不會變
      expect(
        after.width / after.height,
        isNot(closeTo(before.width / before.height, 0.01)),
      );
      // 按完成：回傳的 0~1 框就是畫面上這一個
      await t.tap(find.text('完成'));
      await t.pumpAndSettle();
      final r = (await popped)!;
      expect(r.left, closeTo((after.left - view.left) / view.width, 1e-6));
      expect(r.top, closeTo((after.top - view.top) / view.height, 1e-6));
      expect(r.width, closeTo(after.width / view.width, 1e-6));
      expect(r.height, closeTo(after.height / view.height, 1e-6));
    });

    testWidgets('水平拉開只變寬，高完全不動', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      final (_, before) = _geometry(t);
      final c = before.center;
      // 兩指擺在同一條水平線上（垂直距離 0），左指拉 35、右指拉 25
      final a0 = c + const Offset(-40, 0);
      final b0 = c + const Offset(40, 0);
      await _pinch(
        t,
        a0: a0,
        a1: a0 + const Offset(-35, 0),
        b0: b0,
        b1: b0 + const Offset(25, 0),
      );
      final (_, after) = _geometry(t);
      expect(after.left, closeTo(before.left - 35, 0.5));
      expect(after.right, closeTo(before.right + 25, 0.5));
      expect(after.top, closeTo(before.top, 1e-6));
      expect(after.bottom, closeTo(before.bottom, 1e-6));
    });

    testWidgets('垂直拉開只變高，寬完全不動', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      final (_, before) = _geometry(t);
      final c = before.center;
      final a0 = c + const Offset(0, -40);
      final b0 = c + const Offset(0, 40);
      await _pinch(
        t,
        a0: a0,
        a1: a0 + const Offset(0, -20),
        b0: b0,
        b1: b0 + const Offset(0, 40),
      );
      final (_, after) = _geometry(t);
      expect(after.top, closeTo(before.top - 20, 0.5));
      expect(after.bottom, closeTo(before.bottom + 40, 0.5));
      expect(after.left, closeTo(before.left, 1e-6));
      expect(after.right, closeTo(before.right, 1e-6));
    });

    testWidgets('兩指一起移就是搬：大小不變', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      final (_, before) = _geometry(t);
      final c = before.center;
      final a0 = c + const Offset(-40, -20);
      final b0 = c + const Offset(40, 20);
      await _pinch(
        t,
        a0: a0,
        a1: a0 + const Offset(15, -25),
        b0: b0,
        b1: b0 + const Offset(15, -25),
      );
      final (_, after) = _geometry(t);
      expect(after.width, closeTo(before.width, 1e-6));
      expect(after.height, closeTo(before.height, 1e-6));
      expect(after.left, closeTo(before.left + 15, 0.5));
      expect(after.top, closeTo(before.top - 25, 0.5));
    });

    testWidgets('拉過頭不出圖；捏到底不小於最小邊、不反轉', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      final (view, before) = _geometry(t);
      final c = before.center;
      await _pinch(
        t,
        a0: c + const Offset(-30, -30),
        a1: c + const Offset(-600, -600),
        b0: c + const Offset(30, 30),
        b1: c + const Offset(600, 600),
        steps: 10,
      );
      final (_, big) = _geometry(t);
      expect(big.left, closeTo(view.left, 1e-6));
      expect(big.top, closeTo(view.top, 1e-6));
      expect(big.right, closeTo(view.right, 1e-6));
      expect(big.bottom, closeTo(view.bottom, 1e-6));
      // 再捏到幾乎重疊：框現在是整張（354×472），兩指靠近 338／458
      // 會把寬高算到 16／14，兩個方向都撞到最小邊（32）
      await _pinch(
        t,
        a0: c + const Offset(-170, -230),
        a1: c + const Offset(-1, -1),
        b0: c + const Offset(170, 230),
        b1: c + const Offset(1, 1),
        steps: 10,
      );
      final (_, small) = _geometry(t);
      expect(small.width, closeTo(32, 0.5));
      expect(small.height, closeTo(32, 0.5));
      expect(small.center.dx, closeTo(c.dx, 1));
      expect(small.center.dy, closeTo(c.dy, 1));
      expect(
        view.contains(small.topLeft) && view.contains(small.bottomRight),
        isTrue,
      );
    });

    testWidgets('第二指中途才放上來：以那一刻的框重新起手，不跳', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      final (_, before) = _geometry(t);
      final c = before.center;
      final a = await t.createGesture(pointer: 21);
      final b = await t.createGesture(pointer: 22);
      // 一指先搬 20
      await a.down(c);
      await t.pump();
      await a.moveTo(c + const Offset(10, 0));
      await t.pump();
      await a.moveTo(c + const Offset(20, 0));
      await t.pump();
      final (_, shifted) = _geometry(t);
      expect(shifted.left, closeTo(before.left + 20, 0.5));
      expect(shifted.width, closeTo(before.width, 1e-6));
      // 第二指放上來，然後兩指水平拉開各 30
      final a0 = c + const Offset(20, 0);
      final b0 = c + const Offset(80, 0);
      await b.down(b0);
      await t.pump();
      for (var i = 1; i <= 5; i++) {
        await a.moveTo(a0 + Offset(-6.0 * i, 0));
        await b.moveTo(b0 + Offset(6.0 * i, 0));
        await t.pump();
        final (_, mid) = _geometry(t);
        // 一路上每一步都是「搬完的框 ± 手指到目前為止拉的量」，沒有跳
        expect(mid.left, closeTo(shifted.left - 6.0 * i, 0.5));
        expect(mid.right, closeTo(shifted.right + 6.0 * i, 0.5));
        expect(mid.top, closeTo(shifted.top, 1e-6));
      }
      await a.up();
      await b.up();
      await t.pump();
    });
  });

  group('鎖比例的雙指', () {
    testWidgets('1:1：兩指怎麼拉都是正方形，繞著兩指中點', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      await t.tap(find.text('1:1'));
      await t.pump();
      final (_, before) = _geometry(t);
      expect(before.width, closeTo(before.height, 1e-6));
      final c = before.center;
      // 只往水平拉：兩指距離 80 → 120（1.5 倍），中點不動
      await _pinch(
        t,
        a0: c + const Offset(-40, 0),
        a1: c + const Offset(-60, 0),
        b0: c + const Offset(40, 0),
        b1: c + const Offset(60, 0),
      );
      final (_, after) = _geometry(t);
      expect(after.width, closeTo(after.height, 1e-6));
      expect(after.width, closeTo(before.width * 1.5, 0.5));
      expect(after.center.dx, closeTo(c.dx, 0.5));
      expect(after.center.dy, closeTo(c.dy, 0.5));
    });

    testWidgets('16:9 捏到底：兩邊都不小於最小邊，比例不破', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      await t.tap(find.text('16:9'));
      await t.pump();
      final (view, before) = _geometry(t);
      expect(before.width / before.height, closeTo(16 / 9, 1e-6));
      final c = before.center;
      await _pinch(
        t,
        a0: c + const Offset(-60, -20),
        a1: c + const Offset(-1, 0),
        b0: c + const Offset(60, 20),
        b1: c + const Offset(1, 0),
        steps: 10,
      );
      final (_, after) = _geometry(t);
      expect(after.width / after.height, closeTo(16 / 9, 1e-6));
      expect(after.height, greaterThanOrEqualTo(32 - 1e-6));
      expect(after.width, greaterThanOrEqualTo(32 - 1e-6));
      expect(
        view.contains(after.topLeft) && view.contains(after.bottomRight),
        isTrue,
      );
    });
  });

  group('單指照舊', () {
    testWidgets('框裡拖＝搬整塊、拖角＝改大小', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      final (_, before) = _geometry(t);
      await t.dragFrom(before.center, const Offset(20, 15));
      await t.pump();
      final (_, moved) = _geometry(t);
      expect(moved.width, closeTo(before.width, 1e-6));
      expect(moved.height, closeTo(before.height, 1e-6));
      expect(moved.left, closeTo(before.left + 20, 0.5));
      expect(moved.top, closeTo(before.top + 15, 0.5));
      await t.dragFrom(
        moved.topLeft + const Offset(2, 2),
        const Offset(30, 20),
      );
      await t.pump();
      final (_, resized) = _geometry(t);
      expect(resized.left, closeTo(moved.left + 30, 0.5));
      expect(resized.top, closeTo(moved.top + 20, 0.5));
      expect(resized.right, closeTo(moved.right, 1e-6));
      expect(resized.bottom, closeTo(moved.bottom, 1e-6));
    });
  });

  group('觸控板', () {
    testWidgets('trackpad 捏合沒有手指位置：退回等比，不炸', (t) async {
      await loadPhoto(t);
      await _open(t, photo, initial: half);
      final (_, before) = _geometry(t);
      final c = before.center;
      final g = await t.createGesture(kind: PointerDeviceKind.trackpad);
      await g.panZoomStart(c);
      await t.pump();
      await g.panZoomUpdate(c, scale: 1.25);
      await t.pump();
      await g.panZoomUpdate(c, scale: 1.5);
      await t.pump();
      await g.panZoomEnd();
      await t.pump();
      final (_, after) = _geometry(t);
      expect(t.takeException(), isNull);
      expect(after.width, closeTo(before.width * 1.5, 0.5));
      expect(after.height, closeTo(before.height * 1.5, 0.5));
    });
  });
}
