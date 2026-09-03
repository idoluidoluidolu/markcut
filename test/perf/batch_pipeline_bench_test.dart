// 批次照片管線的分段計時（匯出＋匯入）。預設略過，不進一般測試。
//
// 跑法（PowerShell）：
//   $env:MARKCUT_BENCH='1'; flutter test --no-pub test/perf/batch_pipeline_bench_test.dart
// 跑法（bash）：
//   MARKCUT_BENCH=1 flutter test --no-pub test/perf/batch_pipeline_bench_test.dart
//
// 桌機數字不是 iPhone 數字，但各段之間的「比例」告訴你時間花在哪——
// 這支要回答的是「該砍哪一段」，不是「手機上要幾秒」。
// 同時也是等價性測試：新舊兩條路的 PNG 位元組要一模一樣、
// BMP 包裝解回來要跟 raw RGBA 逐像素相同（這兩項不用 MARKCUT_BENCH 也會跑）
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/bmp_wrap.dart';
import 'package:markcut/services/photo_thumbs.dart';
import 'package:markcut/services/watermark_renderer.dart';

final _bench = Platform.environment['MARKCUT_BENCH'] == '1';

/// 一段的耗時（毫秒）
final _rows = <String>[];

Future<T> _t<T>(String name, Future<T> Function() f) async {
  final sw = Stopwatch()..start();
  final r = await f();
  sw.stop();
  _rows.add(
    '${name.padRight(38)} ${sw.elapsedMilliseconds.toString().padLeft(6)} ms',
  );
  return r;
}

int _rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

/// 有雜訊的測試照片（純漸層會讓 PNG/JPEG 壓得不真實地快）
Future<Uint8List> _noiseRgba(int w, int h) async {
  final out = Uint8List(w * h * 4);
  var s = 0x9E3779B9;
  var i = 0;
  for (var y = 0; y < h; y++) {
    final gy = (y * 255 ~/ h);
    for (var x = 0; x < w; x++) {
      s ^= s << 13;
      s ^= s >>> 17;
      s ^= s << 5;
      s &= 0xFFFFFFFF;
      final n = s & 0x3F; // 0~63 的雜訊
      out[i] = ((x * 255 ~/ w) * 3 ~/ 4 + n).clamp(0, 255);
      out[i + 1] = (gy * 3 ~/ 4 + n).clamp(0, 255);
      out[i + 2] = (128 + n).clamp(0, 255);
      out[i + 3] = 255;
      i += 4;
    }
  }
  return out;
}

Future<Uint8List> _logoPngB64() async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawCircle(
    const ui.Offset(256, 256),
    240,
    ui.Paint()..color = const ui.Color(0xCCFF6600),
  );
  c.drawRect(
    const ui.Rect.fromLTWH(100, 100, 312, 312),
    ui.Paint()..color = const ui.Color(0x8800AAFF),
  );
  final im = await rec.endRecording().toImage(512, 512);
  final png = await im.toByteData(format: ui.ImageByteFormat.png);
  im.dispose();
  return png!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List bytes, {int? targetWidth}) async {
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
  final f = await codec.getNextFrame();
  codec.dispose();
  return f.image;
}

/// 舊的量尺寸（batch_watermark_screen 以前的 _dimsOf）
Future<(int, int)?> _oldDims(Uint8List bytes) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(buf);
  final d = (desc.width, desc.height);
  desc.dispose();
  buf.dispose();
  return d;
}

/// 舊的縮圖（以前的 _shrink）
Future<Uint8List?> _oldShrink(Uint8List src, int longSide) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(src);
  final desc = await ui.ImageDescriptor.encoded(buf);
  final w = desc.width, h = desc.height;
  final long = w > h ? w : h;
  final scale = longSide / long;
  final codec = await desc.instantiateCodec(
    targetWidth: (w * scale).round().clamp(1, longSide),
    targetHeight: (h * scale).round().clamp(1, longSide),
  );
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  desc.dispose();
  buf.dispose();
  return png?.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BMP 包裝：解回來跟 raw RGBA 逐像素相同（含列補齊）', () async {
    // 寬 5：一列 15 位元組，要補到 16——補齊那條路也要驗
    const w = 5, h = 3;
    final rgba = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      rgba[i * 4] = i * 7;
      rgba[i * 4 + 1] = 255 - i * 5;
      rgba[i * 4 + 2] = i * 13;
      rgba[i * 4 + 3] = 255;
    }
    for (final bmp in [
      rgbaToBmp24(rgba, w, h),
      await rgbaToBmp24InIsolate(rgba, w, h),
    ]) {
      expect(bmp.length, 54 + 16 * h);
      final dec = img.decodeBmp(bmp)!;
      expect(dec.width, w);
      expect(dec.height, h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final p = dec.getPixel(x, y);
          final i = (y * w + x) * 4;
          expect([p.r, p.g, p.b], [rgba[i], rgba[i + 1], rgba[i + 2]]);
        }
      }
    }
  });

  test('新舊兩條路的 PNG 位元組一模一樣（小圖，每次都跑）', () async {
    final raw = await _noiseRgba(320, 240);
    final src = await _rawToPng(raw, 320, 240);
    final s = WatermarkSettings();
    final old = await WatermarkRenderer.renderPhotoComposite(
      src,
      s,
      canvasAspect: 16 / 9,
    );
    final im = await WatermarkRenderer.renderPhotoImage(
      src,
      s,
      canvasAspect: 16 / 9,
    );
    final neu = (await im.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    im.dispose();
    expect(listEquals(old, neu), isTrue);
  });

  test(
    '批次照片管線分段計時',
    () async {
      final dir = Directory.systemTemp.createTempSync('markcut_bench');
      final logoB64 = base64Encode(await _logoPngB64());
      final cases = <(String, int, int)>[
        ('12MP 4000x3000', 4000, 3000),
        ('4K 3840x2160', 3840, 2160),
      ];
      for (final (label, w, h) in cases) {
        _rows.add('');
        _rows.add('===== $label =====');
        // 素材：JPEG q90（相簿挑出來的就是 JPEG）
        final raw = await _noiseRgba(w, h);
        final jpg = img.encodeJpg(
          img.Image.fromBytes(
            width: w,
            height: h,
            bytes: raw.buffer,
            numChannels: 4,
          ),
          quality: 90,
        );
        final path = '${dir.path}/in_${w}x$h.jpg';
        File(path).writeAsBytesSync(jpg);
        _rows.add(
          'input JPEG ${(jpg.length / 1024 / 1024).toStringAsFixed(1)} MB',
        );

        for (final (sname, settings) in [
          ('default text', WatermarkSettings()),
          (
            'text + logo',
            WatermarkSettings(
              logo: LogoMark(enabled: true, b64: logoB64, sizeFrac: 0.3),
            ),
          ),
        ]) {
          _rows.add('--- $sname ---  rss ${_rssMb()} MB');
          // 匯出：讀檔
          final bytes = await _t(
            'export: readAsBytes',
            () => File(path).readAsBytes(),
          );
          // 匯出：解碼
          final dec = await _t('export: decode full-res', () => _decode(bytes));
          dec.dispose();
          // 匯出：舊路整段（解碼＋合成＋PNG）
          final oldPng = await _t(
            'export: OLD renderPhotoComposite (png)',
            () => WatermarkRenderer.renderPhotoComposite(bytes, settings),
          );
          // 匯出：新路
          final im = await _t(
            'export: NEW renderPhotoImage (decode+raster)',
            () => WatermarkRenderer.renderPhotoImage(bytes, settings),
          );
          // 浮水印本身的錄製成本（不含 raster）
          await _t('export: drawMarks record only', () async {
            final rec = ui.PictureRecorder();
            final c = ui.Canvas(rec);
            await WatermarkRenderer.drawMarks(
              c,
              settings,
              w.toDouble(),
              h.toDouble(),
            );
            rec.endRecording().dispose();
          });
          final png = await _t(
            'export: toByteData(png)',
            () => im.toByteData(format: ui.ImageByteFormat.png),
          );
          final rawOut = await _t(
            'export: toByteData(rawRgba)',
            () => im.toByteData(format: ui.ImageByteFormat.rawRgba),
          );
          final rawList = rawOut!.buffer.asUint8List();
          final bmp1 = await _t(
            'export: rgbaToBmp24 (main isolate)',
            () async => rgbaToBmp24(rawList, im.width, im.height),
          );
          final bmp2 = await _t(
            'export: rgbaToBmp24InIsolate',
            () => rgbaToBmp24InIsolate(rawList, im.width, im.height),
          );
          expect(listEquals(bmp1, bmp2), isTrue);
          // 純 Dart JPEG 只是「編碼一次 JPEG 大概什麼量級」的參考，
          // 手機上是 ImageIO 硬體加速，不是這個數字
          await _t('ref: pure-Dart JPEG q92 (proxy only)', () async {
            return img.encodeJpg(
              img.Image.fromBytes(
                width: im.width,
                height: im.height,
                bytes: rawList.buffer,
                numChannels: 4,
              ),
              quality: 92,
            );
          });
          // 原生端今天要對 PNG 做的事：解回點陣。純 Dart 只是量級參考
          await _t('ref: pure-Dart PNG decode (proxy only)', () async {
            return img.decodePng(oldPng);
          });
          _rows.add(
            'sizes: png ${(oldPng.length / 1048576).toStringAsFixed(1)} MB, '
            'raw ${(rawList.length / 1048576).toStringAsFixed(1)} MB, '
            'bmp ${(bmp1.length / 1048576).toStringAsFixed(1)} MB   rss ${_rssMb()} MB',
          );
          // 等價：新舊 PNG 位元組相同
          expect(
            listEquals(oldPng, png!.buffer.asUint8List()),
            isTrue,
            reason: '新舊路 PNG 不同',
          );
          // 等價：BMP 解回來 == raw（抽樣 20000 個像素）
          final decBmp = img.decodeBmp(bmp1)!;
          var s = 12345;
          for (var k = 0; k < 20000; k++) {
            s = (s * 1103515245 + 12345) & 0x7FFFFFFF;
            final x = s % im.width, y = (s ~/ im.width) % im.height;
            final p = decBmp.getPixel(x, y);
            final i = (y * im.width + x) * 4;
            expect(
              [p.r, p.g, p.b],
              [rawList[i], rawList[i + 1], rawList[i + 2]],
              reason: 'BMP 像素 ($x,$y) 跟 raw 不同',
            );
          }
          im.dispose();

          // 流水線可行性：兩張同時 toByteData(png)，牆鐘 vs 各自相加
          final a = await WatermarkRenderer.renderPhotoImage(bytes, settings);
          final b = await WatermarkRenderer.renderPhotoImage(bytes, settings);
          final sw = Stopwatch()..start();
          await Future.wait([
            a.toByteData(format: ui.ImageByteFormat.png),
            b.toByteData(format: ui.ImageByteFormat.png),
          ]);
          _rows.add(
            '${'export: 2x toByteData(png) concurrently'.padRight(38)} ${sw.elapsedMilliseconds.toString().padLeft(6)} ms',
          );
          a.dispose();
          b.dispose();
        }

        // ===== 匯入 =====
        _rows.add('--- import ---  rss ${_rssMb()} MB');
        final bytes = await _t(
          'import: readAsBytes',
          () => File(path).readAsBytes(),
        );
        await _t('import: OLD _dimsOf (descriptor)', () => _oldDims(bytes));
        await _t(
          'import: OLD _shrink (descriptor+codec@160+png)',
          () => _oldShrink(bytes, 160),
        );
        final probe = await _t(
          'import: NEW probePhoto(path) dims+thumb',
          () => probePhoto(
            path: path,
            readBytes: () => File(path).readAsBytes(),
            longSide: 160,
          ),
        );
        expect(probe!.dims, (w, h));
        expect(probe.thumb, isNotNull);
        final oldThumb = await _oldShrink(bytes, 160);
        expect(listEquals(oldThumb, probe.thumb), isTrue, reason: '縮圖位元組不同');
        final pv = await _t(
          'import: preview decode targetWidth 1280',
          () => _decode(bytes, targetWidth: 1280),
        );
        pv.dispose();
        final full = await _t(
          'import: preview decode full-res (ref)',
          () => _decode(bytes),
        );
        full.dispose();
      }
      dir.deleteSync(recursive: true);
      // ignore: avoid_print
      print(_rows.join('\n'));
    },
    skip: _bench ? false : '設 MARKCUT_BENCH=1 才跑（十幾秒到一分鐘）',
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<Uint8List> _rawToPng(Uint8List raw, int w, int h) async {
  final im = await _rawToImage(raw, w, h);
  final png = await im.toByteData(format: ui.ImageByteFormat.png);
  im.dispose();
  return png!.buffer.asUint8List();
}

Future<ui.Image> _rawToImage(Uint8List raw, int w, int h) async {
  final buf = await ui.ImmutableBuffer.fromUint8List(raw);
  final desc = ui.ImageDescriptor.raw(
    buf,
    width: w,
    height: h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await desc.instantiateCodec();
  final f = await codec.getNextFrame();
  codec.dispose();
  desc.dispose();
  buf.dispose();
  return f.image;
}
