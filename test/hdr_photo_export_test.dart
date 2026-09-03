// HDR 照片匯出（iOS 17+ 原生路）的 Dart 端。
//
// 原生端沒有 Mac 驗不了，這裡把「Dart 能保證的事」釘死：
// 1. 畫布幾何跟 renderPhotoComposite 一字不差（真的渲染一張比對，
//    不是兩份數學互相抄）
// 2. 送給原生的參數欄位、畫質換算、疊加物有無
// 3. 失敗一律退回（回字串）、成功才存相簿、暫存檔存完就刪
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/hdr_photo_export.dart';
import 'package:markcut/services/watermark_renderer.dart';

/// 一張純色 PNG（測畫布幾何用）
Future<Uint8List> solidPng(int w, int h, ui.Color c) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = c,
  );
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Image> decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  return (await codec.getNextFrame()).image;
}

/// 沒有任何浮水印的設定（只看照片與黑邊）
WatermarkSettings noMarks() => WatermarkSettings(
  text: TextMark(enabled: false),
  logo: LogoMark(enabled: false),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const ch = MethodChannel('markcut/photo');

  group('photoCanvasGeometry', () {
    test('null 或同比例＝不補邊', () {
      final g = photoCanvasGeometry(30, 20, null);
      expect(g.identity, isTrue);
      expect((g.canvasW, g.canvasH, g.photoX, g.photoY), (30, 20, 0.0, 0.0));
      final same = photoCanvasGeometry(30, 20, 1.5);
      expect(same.identity, isTrue);
      // 差 0.001 以內也算同比例（跟 renderPhotoComposite 同一條門檻）
      expect(photoCanvasGeometry(30, 20, 1.5005).identity, isTrue);
    });

    test('比例比照片寬：高貼滿、左右補黑', () {
      final g = photoCanvasGeometry(30, 20, 3.0);
      expect((g.canvasW, g.canvasH), (60, 20));
      expect((g.photoX, g.photoY), (15.0, 0.0));
    });

    test('比例比照片窄：寬貼滿、上下補黑；位移允許 .5', () {
      final g = photoCanvasGeometry(30, 20, 1.0);
      expect((g.canvasW, g.canvasH), (30, 30));
      expect((g.photoX, g.photoY), (0.0, 5.0));
      final odd = photoCanvasGeometry(30, 21, 1.0);
      expect(odd.canvasH, 30);
      expect(odd.photoY, 4.5);
    });

    test('跟 renderPhotoComposite 真的渲染出來的一樣', () async {
      final red = const ui.Color(0xFFFF0000);
      final png = await solidPng(30, 20, red);
      for (final aspect in [1.0, 3.0, 0.5]) {
        final g = photoCanvasGeometry(30, 20, aspect);
        final out = await WatermarkRenderer.renderPhotoComposite(
          png,
          noMarks(),
          canvasAspect: aspect,
        );
        final img = await decode(out);
        expect(
          (img.width, img.height),
          (g.canvasW, g.canvasH),
          reason: 'aspect $aspect 畫布尺寸',
        );
        final raw = (await img.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        int r(int x, int y) => raw[(y * img.width + x) * 4];
        // 照片左上角（照 geometry 的位移）是紅的；再往左/上一格是黑邊
        final px = g.photoX.floor(), py = g.photoY.floor();
        final inside = r(px + 1, py + 1);
        expect(inside, greaterThan(200), reason: 'aspect $aspect 照片區');
        if (px > 0) {
          expect(r(px - 1, py + 1), lessThan(30), reason: 'aspect $aspect 左黑邊');
        }
        if (py > 0) {
          expect(r(px + 1, py - 1), lessThan(30), reason: 'aspect $aspect 上黑邊');
        }
        img.dispose();
      }
    });
  });

  group('exportArgs', () {
    test('欄位齊全、畫質換成 0~1、沒浮水印就沒 overlay 鍵', () {
      final g = photoCanvasGeometry(4000, 3000, 16 / 9);
      final a = HdrPhotoExport.exportArgs(
        src: '/a.heic',
        dest: '/t/out.heic',
        geo: g,
        overlay: null,
        quality: 92,
      );
      expect(a['src'], '/a.heic');
      expect(a['dest'], '/t/out.heic');
      expect(a['outW'], g.canvasW);
      expect(a['outH'], g.canvasH);
      expect(a['photoX'], g.photoX);
      expect(a['photoY'], g.photoY);
      expect(a.containsKey('overlay'), isFalse);
      expect(a['overlayGain'], 1.0);
      expect(a['quality'], closeTo(0.92, 1e-9));
      final b = HdrPhotoExport.exportArgs(
        src: 's',
        dest: 'd',
        geo: g,
        overlay: Uint8List.fromList([1, 2, 3]),
        quality: 1000,
        overlayGain: 3,
      );
      expect(b['overlay'], isA<Uint8List>());
      expect(b['quality'], 1.0);
      expect(b['overlayGain'], 3.0);
    });
  });

  group('probe', () {
    tearDown(() {
      messenger.setMockMethodCallHandler(ch, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('非 iOS 直接 null（不碰通道）', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var called = false;
      messenger.setMockMethodCallHandler(ch, (c) async {
        called = true;
        return {'hdr': true, 'w': 1, 'h': 1};
      });
      expect(await HdrPhotoExport.probe('/x.heic'), isNull);
      expect(called, isFalse);
    });

    test('iOS：讀回 hdr/w/h；通道炸掉回 null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      messenger.setMockMethodCallHandler(ch, (c) async {
        expect(c.method, 'probe');
        expect(c.arguments, '/x.heic');
        return {'hdr': true, 'w': 4032, 'h': 3024};
      });
      final p = await HdrPhotoExport.probe('/x.heic');
      expect(p, isNotNull);
      expect((p!.hdr, p.w, p.h), (true, 4032, 3024));

      messenger.setMockMethodCallHandler(ch, (c) async {
        throw PlatformException(code: 'boom');
      });
      expect(await HdrPhotoExport.probe('/x.heic'), isNull);
    });
  });

  group('exportToGallery', () {
    late Directory tmp;
    final saved = <(String, String)>[];
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hdr_photo_test');
      saved.clear();
      HdrPhotoExport.debugTempDir = () async => tmp.path;
      HdrPhotoExport.debugSaver = (p, album) async => saved.add((p, album));
    });
    tearDown(() {
      messenger.setMockMethodCallHandler(ch, null);
      HdrPhotoExport.debugTempDir = null;
      HdrPhotoExport.debugSaver = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('來源不是 HDR：不叫原生、回原因', () async {
      var called = false;
      messenger.setMockMethodCallHandler(ch, (c) async {
        called = true;
        return null;
      });
      final err = await HdrPhotoExport.exportToGallery(
        srcPath: '/x.heic',
        probe: const HdrPhotoProbe(hdr: false, w: 100, h: 100),
        settings: noMarks(),
      );
      expect(err, isNotNull);
      expect(called, isFalse);
      expect(saved, isEmpty);
    });

    test('原生成功：帶浮水印 PNG（畫布尺寸）、存相簿、刪暫存', () async {
      Map<dynamic, dynamic>? got;
      messenger.setMockMethodCallHandler(ch, (c) async {
        expect(c.method, 'export');
        got = c.arguments as Map;
        // 假裝原生寫了檔，好驗「存完會刪」
        File(got!['dest'] as String).writeAsBytesSync([0]);
        return null;
      });
      final err = await HdrPhotoExport.exportToGallery(
        srcPath: '/x.heic',
        probe: const HdrPhotoProbe(hdr: true, w: 300, h: 200),
        settings: WatermarkSettings(text: TextMark(text: 'hi')),
        canvasAspect: 1.0,
        quality: 78,
        name: 'out1',
      );
      expect(err, isNull);
      expect(got, isNotNull);
      expect(got!['src'], '/x.heic');
      expect(got!['outW'], 300);
      expect(got!['outH'], 300);
      expect(got!['photoY'], 50.0);
      expect(got!['quality'], closeTo(0.78, 1e-9));
      // 浮水印 PNG 是「畫布」尺寸，不是照片尺寸
      final ov = await decode(got!['overlay'] as Uint8List);
      expect((ov.width, ov.height), (300, 300));
      ov.dispose();
      expect(saved.length, 1);
      expect(saved.first.$1, '${tmp.path}/out1.heic');
      expect(saved.first.$2, '浮水印');
      expect(File(saved.first.$1).existsSync(), isFalse, reason: '暫存要刪');
    });

    test('原生回失敗原因：不存相簿、原因往上傳', () async {
      messenger.setMockMethodCallHandler(ch, (c) async => '需要 iOS 17');
      final err = await HdrPhotoExport.exportToGallery(
        srcPath: '/x.heic',
        probe: const HdrPhotoProbe(hdr: true, w: 300, h: 200),
        settings: noMarks(),
      );
      expect(err, '需要 iOS 17');
      expect(saved, isEmpty);
    });

    test('通道炸掉：一樣退回', () async {
      messenger.setMockMethodCallHandler(ch, (c) async {
        throw PlatformException(code: 'x', message: 'no plugin');
      });
      final err = await HdrPhotoExport.exportToGallery(
        srcPath: '/x.heic',
        probe: const HdrPhotoProbe(hdr: true, w: 300, h: 200),
        settings: noMarks(),
      );
      expect(err, isNotNull);
      expect(saved, isEmpty);
    });

    test('存相簿失敗：回原因、暫存照刪', () async {
      messenger.setMockMethodCallHandler(ch, (c) async {
        File((c.arguments as Map)['dest'] as String).writeAsBytesSync([0]);
        return null;
      });
      HdrPhotoExport.debugSaver = (p, a) async => throw StateError('沒權限');
      final err = await HdrPhotoExport.exportToGallery(
        srcPath: '/x.heic',
        probe: const HdrPhotoProbe(hdr: true, w: 300, h: 200),
        settings: noMarks(),
        name: 'out2',
      );
      expect(err, contains('沒權限'));
      expect(File('${tmp.path}/out2.heic').existsSync(), isFalse);
    });
  });
}
