// 預覽上的筆刷馬賽克（沒有合成播放器時：Android、Web、iOS 合成還沒上來）。
// 以前這條拿筆畫的包圍盒整塊碼，跟 iOS 合成器、匯出都對不上：
//   1. 裁切形狀＝筆畫的外輪廓（圓頭圓角粗線），包圍盒的角落不在裡面
//   2. 外輪廓的每一塊同一個繞行方向：重疊處（端點的圓蓋在第一段上、
//      轉角）不能變成破洞
//   3. 真的畫出來：筆畫上被糊、包圍盒裡筆畫外原封不動；純色直接畫遮罩
//      那一筆（跟匯出遮罩同一個畫家）
//   4. 柔邊＝6 圈、由外到內越來越窄；沒柔邊＝1 圈
//   5. 編輯頁沒有合成播放器時，筆刷馬賽克走這個 widget；方形照舊
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/brush_mask.dart';
import 'package:markcut/widgets/brush_mosaic_preview.dart';

import 'editor_harness.dart';

const _stroke = [0.2, 0.3, 0.6, 0.7];

/// 編輯頁算給筆刷馬賽克的那一塊：包圍盒外推半個筆刷＋柔邊尾巴＋2
///（跟 iOS 的 rect、strokeBoundsPx 同一個量）
Rect _rectOf(List<double> s, double brush, Size canvas, {double feather = 0}) {
  final pts = brushStrokePoints(s, canvas.width, canvas.height);
  var r = Rect.fromPoints(pts.first, pts.first);
  for (final p in pts) {
    r = r.expandToInclude(Rect.fromPoints(p, p));
  }
  return r.inflate(brush * canvas.shortestSide / 2 * (1 + feather) + 2);
}

/// 320×180 的畫布：底下 4px 寬的紅藍直條紋（糊過就會混成紫），
/// 筆刷馬賽克疊在上面
Widget _scene(GlobalKey key, MosaicStyle style, {List<double> s = _stroke}) {
  const canvas = Size(320, 180);
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(
        key: key,
        child: SizedBox(
          width: 320,
          height: 180,
          child: Stack(
            children: [
              const Positioned.fill(child: CustomPaint(painter: _Stripes())),
              Positioned.fromRect(
                rect: _rectOf(s, 0.2, canvas),
                child: BrushMosaicPreview(
                  stroke: s,
                  brush: 0.2,
                  style: style,
                  canvas: canvas,
                  rect: _rectOf(s, 0.2, canvas),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Stripes extends CustomPainter {
  const _Stripes();

  @override
  void paint(Canvas canvas, Size size) {
    for (var x = 0.0; x < size.width; x += 4) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 4, size.height),
        Paint()
          ..color = (x ~/ 4).isEven
              ? const Color(0xFFFF0000)
              : const Color(0xFF0000FF),
      );
    }
  }

  @override
  bool shouldRepaint(_Stripes old) => false;
}

/// 截 [key] 那一塊的 RGBA
Future<ByteData> _shot(WidgetTester t, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await t.runAsync(() async {
    final im = await boundary.toImage();
    return (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  }))!;
}

(int, int, int) _rgb(ByteData d, int x, int y) {
  final i = (y * 320 + x) * 4;
  return (d.getUint8(i), d.getUint8(i + 1), d.getUint8(i + 2));
}

void main() {
  group('筆畫外輪廓', () {
    // 一個直角轉彎：(0,0) → (100,0) → (100,100)，半寬 10
    final path = brushStrokeOutline(const [
      Offset(0, 0),
      Offset(100, 0),
      Offset(100, 100),
    ], 10);

    test('粗線範圍以內都在、以外都不在', () {
      for (final p in const [
        Offset(50, 0),
        Offset(50, 9),
        Offset(50, -9),
        Offset(100, 50),
        Offset(109, 50),
        Offset(91, 50),
      ]) {
        expect(path.contains(p), isTrue, reason: '$p');
      }
      for (final p in const [
        Offset(50, 11),
        Offset(50, -11),
        Offset(111, 50),
        Offset(89, 50),
        Offset(50, 50),
        Offset(-11, 0),
        Offset(100, 111),
      ]) {
        expect(path.contains(p), isFalse, reason: '$p');
      }
    });

    test('圓頭、轉角是圓的，重疊處沒有破洞', () {
      // 端點的圓：只有圓蓋到的地方（-5,0），跟圓疊在第一段上的地方（5,0）
      expect(path.contains(const Offset(-5, 0)), isTrue);
      expect(path.contains(const Offset(5, 0)), isTrue);
      expect(path.contains(const Offset(5, 5)), isTrue);
      // 末端的圓疊在第二段上
      expect(path.contains(const Offset(100, 95)), isTrue);
      expect(path.contains(const Offset(100, 105)), isTrue);
      // 轉角外側：圓角補上的那一塊在，方角的尖端不在
      expect(path.contains(const Offset(105, -5)), isTrue);
      expect(path.contains(const Offset(109, -9)), isFalse);
      // 轉角內側：兩段＋圓三層疊在一起
      expect(path.contains(const Offset(95, 5)), isTrue);
    });

    test('單點＝一個圓；沒有點／半寬 0＝空的', () {
      final dot = brushStrokeOutline(const [Offset(50, 50)], 10);
      expect(dot.contains(const Offset(58, 50)), isTrue);
      expect(dot.contains(const Offset(50, 41)), isTrue);
      expect(dot.contains(const Offset(58, 58)), isFalse);
      expect(brushStrokeOutline(const [], 10).getBounds(), Rect.zero);
      expect(
        brushStrokeOutline(const [Offset(1, 1)], 0).getBounds(),
        Rect.zero,
      );
    });
  });

  group('預覽 widget', () {
    testWidgets('模糊：筆畫上糊成紫的，包圍盒裡筆畫外還是純紅純藍', (t) async {
      final key = GlobalKey();
      await t.pumpWidget(_scene(key, MosaicStyle(type: 1, strength: 1)));
      expect(find.byType(ClipPath), findsOneWidget, reason: '沒柔邊＝1 圈');
      expect(find.byType(BackdropFilter), findsOneWidget);
      final d = await _shot(t, key);
      // 中線 (64,54)→(192,126)、半徑 18；法線 (-0.490, 0.872)
      const mid = Offset(128, 90), n = Offset(-0.4903, 0.8716);
      for (final off in [0.0, 8.0, -8.0]) {
        final p = mid + n * off;
        final (r, _, b) = _rgb(d, p.dx.round(), p.dy.round());
        expect(r, greaterThan(50), reason: '筆畫上 $off：紅藍混在一起');
        expect(b, greaterThan(50), reason: '筆畫上 $off：紅藍混在一起');
      }
      // 包圍盒 (44,34)~(212,146) 裡、筆畫外：一格都沒糊
      for (final (x, y) in const [(48, 140), (60, 120), (205, 40), (190, 60)]) {
        final (r, _, b) = _rgb(d, x, y);
        expect(
          (r == 255 && b == 0) || (r == 0 && b == 255),
          isTrue,
          reason: '($x,$y) 不該被糊：$r,$b',
        );
      }
    });

    testWidgets('裁切形狀：中線上在、包圍盒角落不在', (t) async {
      final key = GlobalKey();
      await t.pumpWidget(_scene(key, MosaicStyle(type: 1)));
      final rect = _rectOf(_stroke, 0.2, const Size(320, 180));
      final clip = t.widget<ClipPath>(find.byType(ClipPath));
      final path = clip.clipper!.getClip(rect.size);
      expect(path.contains(const Offset(128, 90) - rect.topLeft), isTrue);
      expect(path.contains(const Offset(48, 140) - rect.topLeft), isFalse);
      expect(path.contains(const Offset(205, 40) - rect.topLeft), isFalse);
    });

    testWidgets('柔邊：6 圈，由外到內越來越窄', (t) async {
      final key = GlobalKey();
      await t.pumpWidget(_scene(key, MosaicStyle(type: 1, feather: 0.5)));
      final clips = t.widgetList<ClipPath>(find.byType(ClipPath)).toList();
      expect(clips, hasLength(6));
      expect(find.byType(BackdropFilter), findsNWidgets(6));
      final rect = _rectOf(_stroke, 0.2, const Size(320, 180));
      double width(ClipPath c) {
        // 沿著法線往外找，最遠還在裡面的那一點＝這一圈的半寬
        final path = c.clipper!.getClip(rect.size);
        var w = 0.0;
        for (var d = 0.0; d < 40; d += 0.25) {
          final p =
              const Offset(128, 90) +
              const Offset(-0.4903, 0.8716) * d -
              rect.topLeft;
          if (path.contains(p)) w = d;
        }
        return w;
      }

      final ws = clips.map(width).toList();
      for (var i = 1; i < ws.length; i++) {
        expect(ws[i], lessThan(ws[i - 1]), reason: '$ws');
      }
      // 柔邊 9px：線寬 27（半寬 13.5）、σ 4.5 → 最外圈 22.5、最內圈 4.5
      expect(ws.first, closeTo(22.5, 0.6));
      expect(ws.last, closeTo(4.5, 0.6));
    });

    testWidgets('純色：直接畫那一筆，不用 BackdropFilter', (t) async {
      final key = GlobalKey();
      await t.pumpWidget(_scene(key, MosaicStyle(type: 2, color: 0xFF00FF00)));
      expect(find.byType(BackdropFilter), findsNothing);
      final d = await _shot(t, key);
      expect(_rgb(d, 128, 90), (0, 255, 0));
      expect(_rgb(d, 96, 72), (0, 255, 0));
      final (r, g, b) = _rgb(d, 48, 140);
      expect(g, 0, reason: '包圍盒角落不塗：$r,$g,$b');
    });
  });

  group('編輯頁', () {
    setUpAll(() {
      final b = TestWidgetsFlutterBinding.ensureInitialized();
      bigPhoneView(b);
      mockEditorPlugins(b);
    });
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('沒有合成播放器：筆刷馬賽克只碼筆畫，方形照舊', (t) async {
      await t.pumpWidget(
        editorApp(const VideoEditorScreen(blank: true, debugAndroid: true)),
      );
      await tick(t, 5);
      VideoEditorScreen.debugTimeline!((tl) {
        tl.sources
          ..add(
            MediaSource(
              path: '',
              name: '筆刷馬賽克',
              kind: ClipKind.mosaic,
              duration: 3600,
              mosaicStyle: MosaicStyle(type: 1, feather: 0.5),
              mosaicStroke: List.of(_stroke),
              mosaicBrush: 0.2,
            ),
          )
          ..add(
            MediaSource(
              path: '',
              name: '馬賽克',
              kind: ClipKind.mosaic,
              duration: 3600,
              mosaicStyle: MosaicStyle(),
            ),
          );
        tl.clips
          ..add(
            TimelineClip(
              id: tl.nextId(),
              sourceIndex: 0,
              trimStart: 0,
              trimEnd: 3,
              offset: 0,
              track: 0,
            ),
          )
          ..add(
            TimelineClip(
              id: tl.nextId(),
              sourceIndex: 1,
              trimStart: 0,
              trimEnd: 3,
              offset: 0,
              track: 1,
            ),
          );
      });
      await tick(t, 15);
      final previews = find.byType(BrushMosaicPreview);
      expect(previews, findsOneWidget, reason: '只有筆刷那一塊走筆畫預覽');
      final w = t.widget<BrushMosaicPreview>(previews);
      expect(w.stroke, _stroke);
      expect(w.brush, 0.2);
      // 畫面上那一塊＝筆畫包圍盒外推半個筆刷＋柔邊尾巴（不是片段
      // px/py/scale 的方框）
      final canvas = w.canvas;
      final want = _rectOf(_stroke, 0.2, canvas, feather: 0.5);
      expect(w.rect.left, closeTo(want.left, 0.01));
      expect(w.rect.top, closeTo(want.top, 0.01));
      expect(w.rect.width, closeTo(want.width, 0.01));
      expect(w.rect.height, closeTo(want.height, 0.01));
      // 柔邊＝6 圈裁切；方形那塊沒有 ClipPath（還是包圍盒整塊）
      expect(
        find.descendant(of: previews, matching: find.byType(ClipPath)),
        findsNWidgets(6),
      );
      await tick(t, 100);
      expect(t.takeException(), isNull);
    });
  });
}
