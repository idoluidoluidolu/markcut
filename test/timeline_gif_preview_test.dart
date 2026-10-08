import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/timeline_gif_preview.dart';

/// 手工組一支 1×1 的 GIF：每格一種顏色（調色盤 紅／綠／藍／白），
/// [delaysCs] 是每格的延遲（百分之一秒）。[trailer] false＝截斷檔
Uint8List _gif(List<int> delaysCs, {bool trailer = true}) {
  final b = BytesBuilder();
  b.add('GIF89a'.codeUnits);
  b.add([1, 0, 1, 0, 0x91, 0, 0]); // 1×1、全域調色盤 4 色
  b.add([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]);
  b.add([0x21, 0xff, 0x0b, ...'NETSCAPE2.0'.codeUnits, 3, 1, 0, 0, 0]);
  for (var i = 0; i < delaysCs.length; i++) {
    final d = delaysCs[i];
    b.add([0x21, 0xf9, 4, 0x04, d & 0xff, d >> 8, 0, 0]);
    b.add([0x2c, 0, 0, 0, 0, 1, 0, 1, 0, 0]);
    // LZW（最小碼長 2）：清除碼 4、顏色 i%4、結束碼 5，各 3 bit
    final code = 4 | ((i % 4) << 3) | (5 << 6);
    b.add([2, 2, code & 0xff, code >> 8, 0]);
  }
  if (trailer) b.add([0x3b]);
  return b.toBytes();
}

/// 假的圖：記得自己是第幾格；複本是另一個把手
class _Img {
  _Img(this.frame, this.bytes, this.all) {
    all.add(this);
  }
  final int frame, bytes;
  final List<_Img> all;
  bool disposed = false;
}

class _FakeGif {
  _FakeGif(
    this.durationsMs, {
    this.decoderFrames,
    this.failAt,
    this.failOnce = false,
  });
  final List<int> durationsMs;

  /// 解碼器回報的格數（跟檔頭對不上的情況）
  final int? decoderFrames;

  /// 解到第幾格會壞掉
  final int? failAt;

  /// 只壞一次（一時的失敗，例如記憶體吃緊）
  final bool failOnce;
  var failed = false;
  final images = <_Img>[];
  final decoders = <_Decoder>[];
  var decodes = 0;
}

class _Decoder implements GifPreviewDecoder<_Img> {
  _Decoder(this.gif);
  final _FakeGif gif;
  int _next = 0;
  bool closed = false;

  @override
  int get frameCount => gif.decoderFrames ?? gif.durationsMs.length;

  @override
  Future<(_Img, Duration)> nextFrame() async {
    expect(closed, isFalse, reason: '關掉的解碼器不能再用');
    await Future<void>.delayed(Duration.zero);
    if (gif.failAt == _next && !(gif.failOnce && gif.failed)) {
      gif.failed = true;
      throw StateError('corrupt frame');
    }
    final i = _next++;
    gif.decodes++;
    final ms = gif.durationsMs[i % gif.durationsMs.length];
    return (_Img(i, 4 << 20, gif.images), Duration(milliseconds: ms));
  }

  @override
  void dispose() {
    expect(closed, isFalse, reason: '解碼器不能關兩次');
    closed = true;
  }
}

TimelineGifPreviewPool<_Img> _pool(
  Map<Uint8List, _FakeGif> gifs, {
  int budget = 8 << 20,
}) => TimelineGifPreviewPool<_Img>(
  open: (bytes) async {
    final gif = gifs[bytes]!;
    final d = _Decoder(gif);
    gif.decoders.add(d);
    return d;
  },
  // 預覽那張 1MB（原尺寸 4MB 的當場釋放）
  prepare: (raw) async {
    final small = _Img(raw.frame, 1 << 20, raw.all);
    raw.disposed = true;
    return small;
  },
  bytesOf: (img) => img.bytes,
  clone: (img) => _Img(img.frame, img.bytes, img.all),
  disposeImage: (img) {
    expect(img.disposed, isFalse, reason: '同一個把手不能釋放兩次');
    img.disposed = true;
  },
  byteBudget: budget,
);

/// 等預覽池把手上的解碼做完。照時間等不照圈數：全套並跑、機器很忙時，
/// 真解碼器一格可能要等好一陣子
Future<void> _idle(TimelineGifPreviewPool pool) async {
  final clock = Stopwatch()..start();
  while (pool.running) {
    if (clock.elapsed > const Duration(seconds: 20)) fail('預覽池停不下來');
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('檔頭讀時間表：0 延遲當 100ms、截斷檔交給解碼器', () {
    final t = GifTimeline.read(_gif([10, 20, 0, 30]))!;
    expect(t.endMs, [100, 300, 400, 700]);
    expect(t.frameAt(0.05), 0);
    expect(t.frameAt(0.15), 1);
    expect(t.frameAt(0.35), 2);
    expect(t.frameAt(0.69), 3);
    expect(t.frameAt(0.75), 0, reason: '整支循環');
    expect(GifTimeline.read(_gif([10, 10], trailer: false)), isNull);
    expect(GifTimeline.read(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('順著播：每格只解一次，留著的格子守住總量上限', () async {
    final bytes = _gif(List.filled(60, 10));
    final gif = _FakeGif(List.filled(60, 100));
    final pool = _pool({bytes: gif});
    var notified = 0;
    final view = pool.acquire(bytes, () => notified++);
    for (var f = 0; f < 60; f++) {
      view.seek(f * 0.1 + 0.05);
      await _idle(pool);
      expect(view.image!.frame, f);
      expect(pool.cacheBytes, lessThanOrEqualTo(8 << 20));
    }
    // 播到最後一格時先把下一輪的開頭兩格備好（繞回去要重開一次）
    expect(gif.decodes, lessThanOrEqualTo(62));
    expect(gif.decoders.length, lessThanOrEqualTo(2));
    expect(notified, greaterThan(0));
    pool.dispose();
    expect(gif.images.every((i) => i.disposed), isTrue);
    expect(gif.decoders.every((d) => d.closed), isTrue);
  });

  test('循環接回開頭：第一格在繞回去之前就備好了', () async {
    final bytes = _gif(List.filled(30, 10));
    final gif = _FakeGif(List.filled(30, 100));
    // 3MB＝只留得住 3 格：第一格早就被擠掉，要靠預先解
    final pool = _pool({bytes: gif}, budget: 3 << 20);
    final view = pool.acquire(bytes, () {});
    for (var f = 20; f < 30; f++) {
      view.seek(f * 0.1 + 0.05);
      await _idle(pool);
    }
    view.seek(3.05); // 下一輪的第 0 格
    expect(view.image!.frame, 0, reason: '不用等解碼，當下就換上');
    pool.dispose();
  });

  test('同一支 GIF 被兩個片段在不同進度用：各自一個游標，不會每格從頭解', () async {
    final bytes = _gif(List.filled(100, 10));
    final gif = _FakeGif(List.filled(100, 100));
    final pool = _pool({bytes: gif}, budget: 4 << 20);
    final a = pool.acquire(bytes, () {});
    final b = pool.acquire(bytes, () {});
    expect(pool.sourceCount, 1);
    for (var k = 0; k < 40; k++) {
      a.seek(k * 0.1 + 0.05);
      b.seek(5 + k * 0.1 + 0.05);
      await _idle(pool);
      expect(a.image!.frame, k);
      expect(b.image!.frame, 50 + k);
    }
    // 兩個進度來回跳的話每格都要從頭解：40 格 × 50 ≈ 2000 次
    expect(gif.decodes, lessThan(200));
    expect(gif.decoders.length, lessThanOrEqualTo(3));
    a.dispose();
    b.dispose();
    expect(pool.sourceCount, 0);
    expect(pool.cacheBytes, 0);
    expect(pool.openDecoders, 0);
    pool.dispose();
    expect(gif.images.every((i) => i.disposed), isTrue);
  });

  test('檔頭讀不懂（截斷檔）：改用解碼器量時間，照樣對得上格', () async {
    final bytes = _gif([10, 20, 10, 30], trailer: false);
    final gif = _FakeGif([100, 200, 100, 300]);
    final pool = _pool({bytes: gif});
    final view = pool.acquire(bytes, () {});
    view.seek(0.15);
    await _idle(pool);
    expect(view.image!.frame, 1);
    view.seek(0.65);
    await _idle(pool);
    expect(view.image!.frame, 3);
    view.seek(0.05);
    await _idle(pool);
    expect(view.image!.frame, 0);
    pool.dispose();
    expect(gif.images.every((i) => i.disposed), isTrue);
  });

  test('檔頭的格數跟解碼器對不上：改用解碼器量', () async {
    // 檔頭 3 格×100ms；解碼器說有 4 格
    final bytes = _gif([10, 10, 10]);
    final gif = _FakeGif([100, 100, 100, 100], decoderFrames: 4);
    final pool = _pool({bytes: gif});
    final view = pool.acquire(bytes, () {});
    view.seek(0.35); // 照檔頭會循環回第 0 格，照解碼器是第 3 格
    await _idle(pool);
    expect(view.image!.frame, 3);
    pool.dispose();
  });

  test('解不開的檔：停在最後解好的那格，不會每個時鐘刻度都從頭重解', () async {
    final bytes = _gif(List.filled(10, 10));
    final gif = _FakeGif(List.filled(10, 100), failAt: 5);
    final pool = _pool({bytes: gif});
    final view = pool.acquire(bytes, () {});
    view.seek(0.05);
    await _idle(pool);
    expect(view.image!.frame, 0);
    view.seek(0.65);
    await _idle(pool);
    final opens = gif.decoders.length;
    final decodes = gif.decodes;
    for (var k = 0; k < 20; k++) {
      view.seek(0.7 + k * 0.1);
      await _idle(pool);
    }
    expect(gif.decoders.length, opens);
    expect(gif.decodes, decodes);
    expect(view.image!.frame, 0);
    expect(pool.openDecoders, 0);
    pool.dispose();
    expect(gif.images.every((i) => i.disposed), isTrue);
  });

  test('一時的失敗：新掛上同一支 GIF 的片段會再試一次，舊片段也跟著恢復', () async {
    final bytes = _gif(List.filled(10, 10));
    final gif = _FakeGif(List.filled(10, 100), failAt: 2, failOnce: true);
    final pool = _pool({bytes: gif});
    final first = pool.acquire(bytes, () {});
    first.seek(0.25);
    await _idle(pool);
    expect(first.image, isNull);
    final second = pool.acquire(bytes, () {});
    second.seek(0.25);
    await _idle(pool);
    expect(second.image!.frame, 2);
    expect(first.image!.frame, 2);
    pool.dispose();
    expect(gif.images.every((i) => i.disposed), isTrue);
  });

  test('片段卸下：它的快取跟解碼器一起收掉；收完再掛上照樣能用', () async {
    final bytes = _gif(List.filled(8, 10));
    final gif = _FakeGif(List.filled(8, 100));
    final pool = _pool({bytes: gif});
    var view = pool.acquire(bytes, () {});
    view.seek(0.15);
    // 還在解的途中就卸下
    await Future<void>.delayed(Duration.zero);
    view.dispose();
    await _idle(pool);
    expect(pool.sourceCount, 0);
    expect(pool.cacheBytes, 0);
    expect(pool.openDecoders, 0);
    expect(gif.images.every((i) => i.disposed), isTrue);
    view = pool.acquire(bytes, () {});
    view.seek(0.25);
    await _idle(pool);
    expect(view.image!.frame, 2);
    pool.dispose();
    expect(gif.images.every((i) => i.disposed), isTrue);
  });

  group('真的解碼器', () {
    Future<List<int>> colorOf(ui.Image image) async {
      final data = (await image.toByteData())!;
      return [data.getUint8(0), data.getUint8(1), data.getUint8(2)];
    }

    for (final trailer in [true, false]) {
      test('照時間挑格、倒回去也對（${trailer ? '完整檔' : '截斷檔'}）', () async {
        final bytes = _gif([10, 20, 10, 30], trailer: trailer);
        final pool = createTimelineGifPreviewPool();
        final view = pool.acquire(bytes, () {});
        Future<List<int>> at(double seconds) async {
          view.seek(seconds);
          await _idle(pool);
          return colorOf(view.image!);
        }

        expect(await at(0.15), [0, 255, 0]);
        expect(await at(0.65), [255, 255, 255]);
        expect(await at(0.05), [255, 0, 0]);
        expect(await at(0.35), [0, 0, 255]);
        view.dispose();
        expect(pool.sourceCount, 0);
        pool.dispose();
      });
    }

    test('大尺寸的格子縮到長邊 480 再留', () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawRect(const ui.Rect.fromLTWH(0, 0, 1200, 600), ui.Paint());
      final picture = recorder.endRecording();
      final big = await picture.toImage(1200, 600);
      picture.dispose();
      final small = await resizeGifPreviewFrame(big);
      expect(big.debugDisposed, isTrue);
      expect([small.width, small.height], [480, 240]);
      small.dispose();
    });
  });
}
