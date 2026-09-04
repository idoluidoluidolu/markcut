// 原生照片編碼通道（markcut/photo_save）的 Dart 端：
// 1. 送過去的參數長什麼樣（原生端照這個形狀拆）
// 2. 通道不在（Swift 還沒貼／Android／Web）→ MissingPluginException →
//    當沒這回事、只探一次，不會每張都把 48MB 送過去
// 3. 原生回錯 → 這張退回舊路、下一張照樣再試
// 4. 退路的 PNG 位元組跟 Skia toByteData(png) 一模一樣
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride, listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/native_photo_save.dart';
import 'package:markcut/services/photo_export.dart';

Future<ui.Image> _image(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  c.drawCircle(
    ui.Offset(w / 2, h / 2),
    w / 3,
    ui.Paint()..color = const ui.Color(0xCCFF6600),
  );
  return rec.endRecording().toImage(w, h);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const ch = NativePhotoSave.channel;

  setUp(() {
    NativePhotoSave.debugReset();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(ch, null);
    debugDefaultTargetPlatformOverride = null;
    NativePhotoSave.debugReset();
  });

  group('NativePhotoSave', () {
    test('encodeArgs：欄位名稱、型別、畫質夾在 1~100', () {
      final rgba = Uint8List(4 * 3 * 4);
      final a = NativePhotoSave.encodeArgs(
        rgba: rgba,
        w: 4,
        h: 3,
        jpeg: true,
        quality: 92,
      );
      expect(a.keys.toSet(), {'bytes', 'w', 'h', 'jpeg', 'quality'});
      expect(identical(a['bytes'], rgba), isTrue);
      expect(a['w'], 4);
      expect(a['h'], 3);
      expect(a['jpeg'], isTrue);
      expect(a['quality'], 92);
      expect(
        NativePhotoSave.encodeArgs(
          rgba: rgba,
          w: 4,
          h: 3,
          jpeg: false,
          quality: 0,
        )['quality'],
        1,
      );
      expect(
        NativePhotoSave.encodeArgs(
          rgba: rgba,
          w: 4,
          h: 3,
          jpeg: false,
          quality: 500,
        )['quality'],
        100,
      );
    });

    test('非 iOS：不碰通道，直接 null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var called = false;
      messenger.setMockMethodCallHandler(ch, (c) async {
        called = true;
        return c.method == 'probe' ? true : Uint8List.fromList([1, 2, 3]);
      });
      final out = await NativePhotoSave.encodeRgba(
        rgba: Uint8List(2 * 2 * 4),
        w: 2,
        h: 2,
        jpeg: true,
      );
      expect(out, isNull);
      expect(called, isFalse);
    });

    test('尺寸或位元組不合：不碰通道', () async {
      var called = false;
      messenger.setMockMethodCallHandler(ch, (c) async {
        called = true;
        return true;
      });
      expect(
        await NativePhotoSave.encodeRgba(
          rgba: Uint8List(3), // 不夠 2x2x4
          w: 2,
          h: 2,
          jpeg: true,
        ),
        isNull,
      );
      expect(
        await NativePhotoSave.encodeRgba(
          rgba: Uint8List(16),
          w: 0,
          h: 2,
          jpeg: true,
        ),
        isNull,
      );
      expect(called, isFalse);
    });

    test('通道沒人接（MissingPluginException）：null，而且只探一次', () async {
      // 沒設 mock handler＝跟 Swift 還沒貼進去一模一樣
      final rgba = Uint8List(2 * 2 * 4);
      expect(
        await NativePhotoSave.encodeRgba(rgba: rgba, w: 2, h: 2, jpeg: true),
        isNull,
      );
      expect(await NativePhotoSave.available(), isFalse);
      // 探過一次「不在」之後就記住了：就算現在有人接也不會再問——
      // 這是刻意的（一個 session 內原生端不會憑空出現）
      var called = 0;
      messenger.setMockMethodCallHandler(ch, (c) async {
        called++;
        return c.method == 'probe' ? true : Uint8List.fromList([9]);
      });
      expect(
        await NativePhotoSave.encodeRgba(rgba: rgba, w: 2, h: 2, jpeg: true),
        isNull,
      );
      expect(called, 0);
    });

    test('原生在：probe 只問一次；encodeRgba 參數形狀；回原生給的位元組', () async {
      const w = 5, h = 3;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < rgba.length; i++) {
        rgba[i] = i & 0xFF;
      }
      var probes = 0;
      final seen = <Map<Object?, Object?>>[];
      messenger.setMockMethodCallHandler(ch, (c) async {
        if (c.method == 'probe') {
          probes++;
          expect(c.arguments, isNull);
          return true;
        }
        expect(c.method, 'encodeRgba');
        final a = c.arguments as Map<Object?, Object?>;
        seen.add(a);
        return Uint8List.fromList([0xFF, 0xD8, a['jpeg'] == true ? 1 : 0]);
      });
      final j = await NativePhotoSave.encodeRgba(
        rgba: rgba,
        w: w,
        h: h,
        jpeg: true,
        quality: 80,
      );
      expect(j, [0xFF, 0xD8, 1]);
      final p = await NativePhotoSave.encodeRgba(
        rgba: rgba,
        w: w,
        h: h,
        jpeg: false,
      );
      expect(p, [0xFF, 0xD8, 0]);
      expect(probes, 1, reason: '一個 session 只探一次');
      expect(seen, hasLength(2));
      // 形狀：原生端 guard let 拆的就是這五個鍵
      for (final a in seen) {
        expect(a.keys.toSet(), {'bytes', 'w', 'h', 'jpeg', 'quality'});
        expect(a['bytes'], isA<Uint8List>());
        expect((a['bytes'] as Uint8List).length, w * h * 4);
        expect(listEquals(a['bytes'] as Uint8List, rgba), isTrue);
        expect(a['w'], w);
        expect(a['h'], h);
        expect(a['jpeg'], isA<bool>());
        expect(a['quality'], isA<int>());
      }
      expect(seen[0]['jpeg'], isTrue);
      expect(seen[0]['quality'], 80);
      expect(seen[1]['jpeg'], isFalse);
      expect(seen[1]['quality'], 92, reason: '預設畫質 92');
    });

    test('原生回 FlutterError／空位元組：這張 null，下一張還是會再試', () async {
      final rgba = Uint8List(2 * 2 * 4);
      var encodes = 0;
      messenger.setMockMethodCallHandler(ch, (c) async {
        if (c.method == 'probe') return true;
        encodes++;
        if (encodes == 1) throw PlatformException(code: 'encode', message: '爆');
        if (encodes == 2) return Uint8List(0);
        return Uint8List.fromList([7]);
      });
      expect(
        await NativePhotoSave.encodeRgba(rgba: rgba, w: 2, h: 2, jpeg: true),
        isNull,
      );
      expect(
        await NativePhotoSave.encodeRgba(rgba: rgba, w: 2, h: 2, jpeg: true),
        isNull,
      );
      expect(
        await NativePhotoSave.encodeRgba(rgba: rgba, w: 2, h: 2, jpeg: true),
        [7],
      );
      expect(encodes, 3);
    });
  });

  group('encodePhotoImage', () {
    test('原生在：JPEG/PNG 都走原生，ext 跟著要的格式', () async {
      final im = await _image(40, 30);
      messenger.setMockMethodCallHandler(ch, (c) async {
        if (c.method == 'probe') return true;
        final a = c.arguments as Map<Object?, Object?>;
        expect(a['w'], 40);
        expect(a['h'], 30);
        expect((a['bytes'] as Uint8List).length, 40 * 30 * 4);
        return Uint8List.fromList([a['jpeg'] == true ? 1 : 2]);
      });
      final j = await encodePhotoImage(im, jpeg: true, quality: 85);
      expect((j.via, j.ext), ('native', 'jpg'));
      expect(j.bytes, [1]);
      final p = await encodePhotoImage(im, jpeg: false);
      expect((p.via, p.ext), ('native', 'png'));
      expect(p.bytes, [2]);
      im.dispose();
    });

    test('原生不在：PNG 跟 toByteData(png) 位元組一模一樣', () async {
      final im = await _image(64, 48);
      final ref = (await im.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      final p = await encodePhotoImage(im, jpeg: false);
      expect((p.via, p.ext), ('png', 'png'));
      expect(listEquals(p.bytes, ref), isTrue);
      // 要 JPEG：這台（測試主機）沒有 compress 外掛，BMP 路跟
      // PNG→JPEG 路都會炸，最後照樣給 PNG——跟以前一樣「總比失敗好」
      final j = await encodePhotoImage(im, jpeg: true);
      expect((j.via, j.ext), ('png', 'png'));
      expect(listEquals(j.bytes, ref), isTrue);
      im.dispose();
    });

    test('原生炸掉：PNG 退回 Skia，位元組不變', () async {
      final im = await _image(32, 32);
      messenger.setMockMethodCallHandler(ch, (c) async {
        if (c.method == 'probe') return true;
        throw PlatformException(code: 'encode', message: 'CGImage 建不起來');
      });
      final ref = (await im.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      final p = await encodePhotoImage(im, jpeg: false);
      expect(p.via, 'png');
      expect(listEquals(p.bytes, ref), isTrue);
      im.dispose();
    });
  });
}
