// 從 JSON 讀回來的浮水印設定要夾在滑桿範圍內：壞掉／手改的範本或草稿
// 帶著 sizeFrac=0 進來，平鋪的步進就是 0，畫平鋪的迴圈永遠走不完
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/watermark_renderer.dart';

Future<Uint8List> _png(int side) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final img = await rec.endRecording().toImage(side, side);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('fromJson 夾範圍', () {
    test('文字：sizeFrac、透明度、字距', () {
      final t = TextMark.fromJson({
        'text': 'x',
        'sizeFrac': 0,
        'opacity': 7,
        'spacing': -3,
      });
      expect(t.sizeFrac, greaterThanOrEqualTo(0.01));
      expect(t.opacity, 1.0);
      expect(t.spacing, -0.2);
      final big = TextMark.fromJson({
        'text': 'x',
        'sizeFrac': 99,
        'spacing': 9,
      });
      expect(big.sizeFrac, lessThanOrEqualTo(3.0));
      expect(big.spacing, 0.6);
      // 正常值原封不動
      final ok = TextMark.fromJson({
        'text': 'x',
        'sizeFrac': 0.12,
        'opacity': 0.7,
        'spacing': 0.1,
      });
      expect(ok.sizeFrac, closeTo(0.12, 1e-9));
      expect(ok.opacity, closeTo(0.7, 1e-9));
      expect(ok.spacing, closeTo(0.1, 1e-9));
    });

    test('圖片：sizeFrac、透明度、圓角', () {
      final l = LogoMark.fromJson({'sizeFrac': 0, 'opacity': -1, 'corner': 4});
      expect(l.sizeFrac, greaterThanOrEqualTo(0.01));
      expect(l.opacity, 0.0);
      expect(l.corner, 1.0);
      final ok = LogoMark.fromJson({
        'sizeFrac': 0.32,
        'opacity': 0.8,
        'corner': 0.25,
      });
      expect(ok.sizeFrac, closeTo(0.32, 1e-9));
      expect(ok.opacity, closeTo(0.8, 1e-9));
      expect(ok.corner, closeTo(0.25, 1e-9));
    });
  });

  // 以前 sizeFrac=0＋平鋪：stepX=0，畫平鋪的 for 迴圈永不終止（整個
  // App 卡死）。夾了下限之後這張要畫得完
  test('壞 JSON：sizeFrac=0 的平鋪文字與圖片，烘圖畫得完', () async {
    final logoPng = await _png(20);
    final s = WatermarkSettings.fromJson({
      'texts': [
        {'text': '@x', 'sizeFrac': 0, 'tiled': true},
      ],
      'logos': [
        {'enabled': true, 'b64': _b64(logoPng), 'sizeFrac': 0, 'tiled': true},
      ],
    });
    final png = await WatermarkRenderer.renderOverlayPng(
      s,
      320,
      200,
    ).timeout(const Duration(seconds: 30));
    expect(png, isNotEmpty);
  });

  group('copy() 帶著裁切前的原圖', () {
    test('LogoMark.copy', () {
      final orig = Uint8List.fromList([1, 2, 3]);
      final l = LogoMark(enabled: true)
        ..bytesValue = Uint8List.fromList([9, 9])
        ..origBytes = orig;
      expect(identical(l.copy().origBytes, orig), isTrue);
    });

    test('WatermarkSettings.copy：每一張圖片的原圖都在（更多浮水印那組才能重裁）', () {
      final s = WatermarkSettings();
      s.logo
        ..enabled = true
        ..bytesValue = Uint8List.fromList([1])
        ..origBytes = Uint8List.fromList([7, 7]);
      s.addLogo()
        ..bytesValue = Uint8List.fromList([2])
        ..origBytes = Uint8List.fromList([8, 8]);
      final c = s.copy();
      expect(c.logos.length, 2);
      expect(identical(c.logos[0].origBytes, s.logos[0].origBytes), isTrue);
      expect(identical(c.logos[1].origBytes, s.logos[1].origBytes), isTrue);
      // 不進 JSON（體積）：範本／草稿照舊沒有它
      expect(s.toJson().toString(), isNot(contains('origBytes')));
    });
  });
}

String _b64(Uint8List b) {
  final l = LogoMark()..bytesValue = b;
  return l.b64!;
}
