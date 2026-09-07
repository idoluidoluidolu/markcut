// GIF 成品預覽的幀（稽核 #1）：縮到預覽用得到的大小、總量受上限管，
// 不再把整支原尺寸留在記憶體
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:markcut/services/gif_frames.dart';

/// 一支真的會動的 GIF：[n] 幀、[w]×[h]
String _writeGif(Directory dir, {int n = 12, int w = 200, int h = 100}) {
  final enc = img.GifEncoder(numColors: 16);
  for (var f = 0; f < n; f++) {
    final im = img.Image(width: w, height: h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        im.setPixelRgb(x, y, (x + f * 7) & 0xff, y & 0xff, f * 20);
      }
    }
    enc.addFrame(im, duration: 8); // 1/100 秒為單位＝80ms
  }
  final p = '${dir.path}${Platform.pathSeparator}a.gif';
  File(p).writeAsBytesSync(enc.finish()!);
  return p;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('gif_frames_'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('gifFrameTarget：不放大、不超過預覽區、總量超過預算就整批再縮', () {
    // 小圖：照原樣
    expect(
      gifFrameTarget(
        width: 200,
        height: 100,
        frames: 10,
        maxWidth: 1000,
        maxHeight: 1000,
      ),
      (200, 100),
    );
    // 比預覽區大：縮到預覽區
    expect(
      gifFrameTarget(
        width: 2000,
        height: 1000,
        frames: 10,
        maxWidth: 500,
        maxHeight: 1000,
      ),
      (500, 250),
    );
    // 640×360×225 幀＝207MB：預算 64MB 就縮到約 0.56 倍
    final (w, h) = gifFrameTarget(
      width: 640,
      height: 360,
      frames: 225,
      maxWidth: 1170,
      maxHeight: 2532,
    );
    expect(w * h * 4 * 225, lessThanOrEqualTo(kGifFrameBudget + 225 * 4 * 640));
    expect(w, inInclusiveRange(340, 370));
    expect(h, inInclusiveRange(190, 210));
    // 一般用法（480p、5 秒 12fps＝60 幀）碰不到預算
    expect(
      gifFrameTarget(
        width: 480,
        height: 270,
        frames: 60,
        maxWidth: 1170,
        maxHeight: 2532,
      ),
      (480, 270),
    );
    expect(
      gifFrameTarget(
        width: 0,
        height: 0,
        frames: 1,
        maxWidth: 10,
        maxHeight: 10,
      ),
      (1, 1),
    );
  });

  testWidgets('decodeGifFrames：幀數、時長對；比預覽區大就縮；預算不夠整批再縮；取消回 null 不留幀', (
    t,
  ) async {
    final p = _writeGif(dir);
    await t.runAsync(() async {
      final full = await decodeGifFrames(p, maxWidth: 1000, maxHeight: 1000);
      expect(full, isNotNull);
      expect(full!.images.length, 12);
      expect(full.images.first.width, 200);
      expect(full.images.first.height, 100);
      expect(full.loopMs, 12 * 80);
      expect(full.endMs.last, full.loopMs);
      expect(full.bytes, 12 * 200 * 100 * 4);
      full.dispose();

      final small = await decodeGifFrames(p, maxWidth: 50, maxHeight: 1000);
      expect(small!.images.length, 12);
      expect(small.images.first.width, 50);
      expect(small.images.first.height, 25);
      expect(small.loopMs, 12 * 80, reason: '縮圖不影響時鐘');
      small.dispose();

      // 預算只夠原尺寸的四分之一：每邊縮一半
      final budget = 12 * 100 * 50 * 4;
      final tight = await decodeGifFrames(
        p,
        maxWidth: 1000,
        maxHeight: 1000,
        byteBudget: budget,
      );
      expect(tight!.bytes, lessThanOrEqualTo(budget));
      expect(tight.images.first.width, 100);
      tight.dispose();

      // 幀數上限
      final capped = await decodeGifFrames(
        p,
        maxWidth: 1000,
        maxHeight: 1000,
        maxFrames: 5,
      );
      expect(capped!.images.length, 5);
      capped.dispose();

      // 取消：什麼都不留
      var calls = 0;
      final gone = await decodeGifFrames(
        p,
        maxWidth: 1000,
        maxHeight: 1000,
        cancelled: () => ++calls >= 3,
      );
      expect(gone, isNull);

      // 壞檔
      final bad = '${dir.path}${Platform.pathSeparator}bad.gif';
      File(bad).writeAsBytesSync([1, 2, 3, 4]);
      expect(await decodeGifFrames(bad, maxWidth: 10, maxHeight: 10), isNull);
      expect(
        await decodeGifFrames(
          '${dir.path}${Platform.pathSeparator}nope.gif',
          maxWidth: 10,
          maxHeight: 10,
        ),
        isNull,
      );
    });
  });
}
