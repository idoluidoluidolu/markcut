// 裁切畫面的「原比例」「縮放」（使用者 10-16 指定）：
//
// - 比例那一排多兩顆：自由・原比例・縮放・1:1・3:4・4:3・9:16・16:9，
//   一排排完、窄機子也不切字
// - 原比例：框鎖在這張圖自己的長寬比，拉角落比例不破
// - 縮放：照片尺寸不變、在原尺寸內縮放移動——框固定在整張圖的位置，
//   雙指放大、單指拖曳動的是底下的圖；出檔跟原圖一樣大
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/crop_screen.dart';
import 'package:markcut/services/crop_math.dart';
import 'package:markcut/theme.dart';

Future<Uint8List> _png(int w, int h) async {
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
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

Future<(int, int)> _size(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final s = (frame.image.width, frame.image.height);
  frame.image.dispose();
  codec.dispose();
  return s;
}

final _paint = find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.painter.runtimeType.toString().contains('CropPainter'),
);

/// painter 的幾何（全域座標）：view＝整張圖擺的位置、crop＝框；縮放模式
/// 的 zoomSrc＝框裡看到原圖的哪一塊（圖片像素）
({Rect view, Rect crop, Rect? zoomSrc}) _geometry(WidgetTester t) {
  final p = t.widget<CustomPaint>(_paint).painter as dynamic;
  final origin = t.getTopLeft(_paint);
  return (
    view: (p.view as Rect).shift(origin),
    crop: (p.crop as Rect).shift(origin),
    zoomSrc: p.zoomSrc as Rect?,
  );
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 60 && _paint.evaluate().isEmpty; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await t.pump();
  }
  expect(_paint, findsOneWidget);
}

/// 開 rectOnly 的裁切畫面（拼圖、影片走的那條），回傳按完成之後的框
Future<Future<Rect?>> _openRect(
  WidgetTester t,
  Uint8List bytes, {
  Size surface = const Size(390, 780),
}) async {
  await t.binding.setSurfaceSize(surface);
  addTearDown(() => t.binding.setSurfaceSize(null));
  Future<Rect?>? popped;
  await t.pumpWidget(
    MaterialApp(
      // 同一支測試裡開第二次：換一個 key 才是全新的 Navigator，不然上一次
      // 的裁切頁還疊在最上面、按鈕也還是上一次的那個
      key: UniqueKey(),
      theme: buildStudioTheme(),
      home: Builder(
        builder: (ctx) => Center(
          child: TextButton(
            onPressed: () => popped = pickCropRect(ctx, bytes),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await _settle(t);
  return popped!;
}

Future<void> _pinch(
  WidgetTester t, {
  required Offset a0,
  required Offset a1,
  required Offset b0,
  required Offset b1,
  int steps = 6,
}) async {
  final a = await t.createGesture(pointer: 21);
  final b = await t.createGesture(pointer: 22);
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

/// 單指拖：分幾步走，ScaleGestureRecognizer 才會判成拖曳
Future<void> _drag(WidgetTester t, Offset from, Offset by) async {
  final g = await t.startGesture(from, pointer: 23);
  for (var i = 1; i <= 8; i++) {
    await g.moveTo(from + by * (i / 8));
    await t.pump();
  }
  await g.up();
  await t.pump();
}

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());

  group('縮放的數學（zoomCrop）', () {
    const frame = Rect.fromLTWH(20, 40, 300, 400); // 畫面上整張圖的位置
    const image = Size(900, 1200);
    const full = Rect.fromLTWH(0, 0, 900, 1200);

    test('沒放大也沒移：原封不動', () {
      final r = zoomCrop(
        start: full,
        frame: frame,
        imageSize: image,
        scale: 1,
        focalStart: frame.center,
        focal: frame.center,
      );
      expect(r, full);
    });

    test('繞框中心放大兩倍：看到正中間那一半，比例不變', () {
      final r = zoomCrop(
        start: full,
        frame: frame,
        imageSize: image,
        scale: 2,
        focalStart: frame.center,
        focal: frame.center,
      );
      expect(r.width, closeTo(450, 1e-9));
      expect(r.height, closeTo(600, 1e-9));
      expect(r.center.dx, closeTo(450, 1e-9));
      expect(r.center.dy, closeTo(600, 1e-9));
    });

    test('放大後往右拖：看到的那一塊往左（內容跟著手指走）', () {
      const start = Rect.fromLTWH(225, 300, 450, 600); // 兩倍
      final r = zoomCrop(
        start: start,
        frame: frame,
        imageSize: image,
        scale: 1,
        focalStart: frame.center,
        focal: frame.center + const Offset(60, 0),
      );
      // 畫面 60px＝圖片 60 × 450/300 = 90px
      expect(r.left, closeTo(225 - 90, 1e-9));
      expect(r.top, closeTo(300, 1e-9));
      expect(r.size, start.size);
    });

    test('指尖底下那一點留在指尖底下', () {
      const start = Rect.fromLTWH(100, 200, 600, 800);
      const f0 = Offset(80, 120);
      const f1 = Offset(110, 150);
      final r = zoomCrop(
        start: start,
        frame: frame,
        imageSize: image,
        scale: 1.5,
        focalStart: f0,
        focal: f1,
      );
      Offset toImage(Rect crop, Offset p) =>
          crop.topLeft + (p - frame.topLeft) * (crop.width / frame.width);
      final before = toImage(start, f0);
      final after = toImage(r, f1);
      expect((after - before).distance, lessThan(1e-6));
    });

    test('縮不回整張以外（不留白邊）、最多放大 8 倍、拖不出圖', () {
      final out = zoomCrop(
        start: full,
        frame: frame,
        imageSize: image,
        scale: 0.3,
        focalStart: frame.center,
        focal: frame.center,
      );
      expect(out, full);
      final deep = zoomCrop(
        start: full,
        frame: frame,
        imageSize: image,
        scale: 100,
        focalStart: frame.center,
        focal: frame.center,
      );
      expect(deep.width, closeTo(900 / kCropMaxZoom, 1e-9));
      final dragged = zoomCrop(
        start: const Rect.fromLTWH(225, 300, 450, 600),
        frame: frame,
        imageSize: image,
        scale: 1,
        focalStart: frame.center,
        focal: frame.center + const Offset(5000, -5000),
      );
      expect(dragged.left, 0);
      expect(dragged.bottom, closeTo(1200, 1e-9));
    });

    test('亂捏亂拖 3000 次：永遠在圖裡、比例不破、不比整張大、不小於 1/8', () {
      final rnd = math.Random(7);
      var crop = full;
      for (var i = 0; i < 3000; i++) {
        final f0 = Offset(
          frame.left + rnd.nextDouble() * frame.width,
          frame.top + rnd.nextDouble() * frame.height,
        );
        crop = zoomCrop(
          start: crop,
          frame: frame,
          imageSize: image,
          scale: math.exp((rnd.nextDouble() - 0.5) * 2),
          focalStart: f0,
          focal:
              f0 +
              Offset(
                rnd.nextDouble() * 400 - 200,
                rnd.nextDouble() * 400 - 200,
              ),
        );
        expect(crop.left, greaterThanOrEqualTo(-1e-9));
        expect(crop.top, greaterThanOrEqualTo(-1e-9));
        expect(crop.right, lessThanOrEqualTo(900 + 1e-6));
        expect(crop.bottom, lessThanOrEqualTo(1200 + 1e-6));
        expect(crop.width / crop.height, closeTo(0.75, 1e-9));
        expect(crop.width, greaterThanOrEqualTo(900 / kCropMaxZoom - 1e-9));
      }
    });
  });

  testWidgets('比例那一排：自由・原比例・縮放・1:1・3:4・4:3・9:16・16:9，窄機子也排得下', (t) async {
    final bytes = (await t.runAsync(() => _png(900, 1200)))!;
    for (final width in [390.0, 320.0]) {
      await _openRect(t, bytes, surface: Size(width, 700));
      const labels = ['自由', '原比例', '縮放', '1:1', '3:4', '4:3', '9:16', '16:9'];
      final xs = <double>[];
      for (final l in labels) {
        final chip = find.text(l);
        expect(chip, findsOneWidget, reason: '$width 寬要看得到「$l」');
        final r = t.getRect(chip);
        expect(r.left, greaterThanOrEqualTo(0), reason: '$width：「$l」超出左邊');
        expect(r.right, lessThanOrEqualTo(width), reason: '$width：「$l」超出右邊');
        xs.add(r.center.dx);
      }
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: '順序要照排');
      }
      // 字沒有被切掉：每一格的字都整個在自己的膠囊裡
      for (final l in labels) {
        final pill = find.ancestor(
          of: find.text(l),
          matching: find.byType(Container),
        );
        final text = t.getRect(find.text(l));
        final box = t.getRect(pill.first);
        expect(
          box.contains(text.topLeft) &&
              box.contains(text.bottomRight - const Offset(0.01, 0.01)),
          isTrue,
          reason: '$width：「$l」被膠囊切到',
        );
      }
      expect(t.takeException(), isNull);
    }
  });

  testWidgets('原比例：框鎖在這張圖自己的比例，拉角落比例不破', (t) async {
    // 先拉成別的形狀，再按原比例
    final bytes = (await t.runAsync(() => _png(900, 1200)))!;
    await _openRect(t, bytes);
    await t.tap(find.text('16:9'));
    await t.pump();
    await t.tap(find.text('原比例'));
    await t.pump();
    var g = _geometry(t);
    expect(g.crop.width / g.crop.height, closeTo(0.75, 0.01));
    // 拖左上角往內縮
    await t.dragFrom(g.crop.topLeft + const Offset(2, 2), const Offset(60, 20));
    await t.pump();
    g = _geometry(t);
    expect(g.crop.width, lessThan(g.view.width - 30));
    expect(g.crop.width / g.crop.height, closeTo(0.75, 0.01));
    expect(t.takeException(), isNull);
  });

  testWidgets('縮放：框固定在整張圖、雙指放大、單指拖曳移動，完成回傳原比例的框', (t) async {
    final bytes = (await t.runAsync(() => _png(900, 1200)))!;
    final result = await _openRect(t, bytes);
    await t.tap(find.text('縮放'));
    await t.pump();
    var g = _geometry(t);
    expect(g.crop, g.view, reason: '縮放模式的框就是整張圖的位置');
    expect(g.zoomSrc, isNotNull);
    final img = g.zoomSrc!.size; // 整張（預覽圖的像素）
    // 雙指拉開兩倍：看到的那一塊變一半，框照樣不動
    final c = g.view.center;
    await _pinch(
      t,
      a0: c - const Offset(50, 0),
      a1: c - const Offset(100, 0),
      b0: c + const Offset(50, 0),
      b1: c + const Offset(100, 0),
    );
    g = _geometry(t);
    expect(g.crop, g.view);
    expect(g.zoomSrc!.width, closeTo(img.width / 2, img.width * 0.03));
    expect(g.zoomSrc!.width / g.zoomSrc!.height, closeTo(0.75, 1e-6));
    // 單指往右拖：看到的那一塊往左
    final before = g.zoomSrc!;
    await _drag(t, c, const Offset(60, 0));
    g = _geometry(t);
    expect(g.zoomSrc!.left, lessThan(before.left - 10));
    expect(g.zoomSrc!.size.width, closeTo(before.width, 1e-6));
    final shown = g.zoomSrc!;
    await t.tap(find.text('完成'));
    await t.pumpAndSettle();
    final rect = (await result)!;
    expect(rect.left, closeTo(shown.left / img.width, 1e-6));
    expect(rect.width, closeTo(shown.width / img.width, 1e-6));
    // 原圖比例的框，換成 0~1 之後寬高一樣
    expect(rect.width, closeTo(rect.height, 1e-6), reason: '回傳的框是原圖比例');
    expect(t.takeException(), isNull);
  });

  testWidgets('縮放：還原＝回到整張、還在縮放；換到自由才變回一般裁切框', (t) async {
    final bytes = (await t.runAsync(() => _png(900, 1200)))!;
    await _openRect(t, bytes);
    await t.tap(find.text('縮放'));
    await t.pump();
    final c = _geometry(t).view.center;
    await _pinch(
      t,
      a0: c - const Offset(40, 0),
      a1: c - const Offset(120, 0),
      b0: c + const Offset(40, 0),
      b1: c + const Offset(120, 0),
    );
    expect(_geometry(t).zoomSrc!.width, lessThan(_geometry(t).view.width));
    await t.tap(find.byIcon(Icons.restore));
    await t.pump();
    var g = _geometry(t);
    expect(g.zoomSrc, isNotNull, reason: '還原後還在縮放');
    expect(g.zoomSrc!.topLeft, Offset.zero);
    await t.tap(find.text('自由'));
    await t.pump();
    g = _geometry(t);
    expect(g.zoomSrc, isNull);
    expect(g.crop, g.view, reason: '整張的框');
    expect(t.takeException(), isNull);
  });

  testWidgets('縮放出檔：照片尺寸不變（跟原圖一樣大），有 maxSide 照樣夾', (t) async {
    final src = (await t.runAsync(() => _png(600, 300)))!;
    for (final (maxSide, want) in [(null, (600, 300)), (200, (200, 100))]) {
      Uint8List? out;
      var done = false;
      await t.binding.setSurfaceSize(const Size(390, 780));
      await t.pumpWidget(
        MaterialApp(
          key: UniqueKey(), // 每一輪全新的 Navigator（見 _openRect）
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                out = await cropImage(ctx, src, maxSide: maxSide);
                done = true;
              },
              child: const Text('go'),
            ),
          ),
        ),
      );
      await t.tap(find.text('go'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      await _settle(t);
      await t.tap(find.text('縮放'));
      await t.pump();
      final c = _geometry(t).view.center;
      await _pinch(
        t,
        a0: c - const Offset(30, 0),
        a1: c - const Offset(90, 0),
        b0: c + const Offset(30, 0),
        b1: c + const Offset(90, 0),
      );
      expect(_geometry(t).zoomSrc!.width, lessThan(600 * 0.6));
      await t.tap(find.text('完成'));
      for (var i = 0; i < 12 && !done; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await t.pump(const Duration(milliseconds: 60));
      }
      expect(done, isTrue, reason: 'maxSide $maxSide：裁切頁要把結果 pop 回來');
      expect((await t.runAsync(() => _size(out!)))!, want);
    }
    await t.binding.setSurfaceSize(null);
  });
}
