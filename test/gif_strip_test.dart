// GIF 頁縮圖帶的漸進載入（先粗後細、先到先畫、手勢中讓路）
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/gif_strip.dart';

Uint8List _b(int v) => Uint8List.fromList([v & 0xff, v >> 8]);

void main() {
  group('二分順序', () {
    test('每格剛好一次、先頭尾再中間', () {
      final o = stripFillOrder(10);
      expect(o.length, 10);
      expect(o.toSet(), List.generate(10, (i) => i).toSet());
      expect(o.sublist(0, 3), [0, 9, 4]);
    });

    test('邊界', () {
      expect(stripFillOrder(0), isEmpty);
      expect(stripFillOrder(1), [0]);
      expect(stripFillOrder(2), [0, 1]);
      expect(stripFillOrder(3), [0, 2, 1]);
    });
  });

  group('借最近一格', () {
    test('自己有就自己、沒有借最近的', () {
      final a = _b(1);
      final c = _b(3);
      final cells = <Uint8List?>[a, null, null, c, null];
      expect(nearestLoaded(cells, 0), same(a));
      expect(nearestLoaded(cells, 1), same(a));
      expect(nearestLoaded(cells, 2), same(c));
      expect(nearestLoaded(cells, 4), same(c));
    });

    test('一格都沒有回 null', () {
      expect(nearestLoaded(<Uint8List?>[null, null], 1), isNull);
      expect(nearestLoaded(<Uint8List?>[], 0), isNull);
    });
  });

  group('漸進載入', () {
    test('粗抽整支長度的容忍、逐格回報；細抽半格、一樣的不重畫', () async {
      final calls = <(double, int)>[];
      final painted = <int>[];
      final loader = GifStripLoader(
        duration: 30,
        count: 10,
        fetch: (t, {required tolMs}) async {
          calls.add((t, tolMs));
          // 第 i 格的時間點是 3i+1.5：粗抽回 i；細抽後半段換成不同的圖
          final i = t ~/ 3;
          return _b(tolMs == 30000 ? i : (t < 15 ? i : i + 100));
        },
        onFrame: (i, _) => painted.add(i),
      );
      await loader.run();
      expect(calls.length, 20);
      expect(calls.take(10).every((c) => c.$2 == 30000), isTrue);
      expect(calls.skip(10).every((c) => c.$2 == 1500), isTrue);
      expect(calls.take(10).map((c) => c.$1).toList(), [
        for (final i in stripFillOrder(10)) 30 * (i + 0.5) / 10,
      ]);
      // 粗抽：每格一到就畫、順序照二分
      expect(painted.sublist(0, 10), stripFillOrder(10));
      // 細抽：只有換了圖的後半段重畫
      expect(
        painted.sublist(10),
        stripFillOrder(10).where((i) => i >= 5).toList(),
      );
      expect(loader.frames.every((f) => f != null), isTrue);
    });

    test('關掉細抽只跑一輪', () async {
      var n = 0;
      final loader = GifStripLoader(
        duration: 30,
        count: 10,
        refine: false,
        fetch: (t, {required tolMs}) async {
          n++;
          return _b(1);
        },
        onFrame: (_, _) {},
      );
      await loader.run();
      expect(n, 10);
    });

    test('太短的影片細抽沒意義，不做', () async {
      var n = 0;
      final loader = GifStripLoader(
        duration: 0.1,
        count: 10,
        fetch: (t, {required tolMs}) async {
          n++;
          return _b(1);
        },
        onFrame: (_, _) {},
      );
      expect(loader.fineTolMs, GifStripLoader.fineTolFloorMs);
      await loader.run();
      expect(n, 10);
    });

    test('抽不到的格子留空、其他照畫', () async {
      final loader = GifStripLoader(
        duration: 10,
        count: 4,
        refine: false,
        fetch: (t, {required tolMs}) async => t > 5 ? null : _b(1),
        onFrame: (_, _) {},
      );
      await loader.run();
      expect(loader.frames.map((f) => f != null).toList(), [
        true,
        true,
        false,
        false,
      ]);
    });

    test('取消就停', () async {
      var n = 0;
      late final GifStripLoader loader;
      loader = GifStripLoader(
        duration: 30,
        count: 10,
        fetch: (t, {required tolMs}) async {
          n++;
          return _b(n);
        },
        onFrame: (i, _) {
          if (n == 3) loader.cancel();
        },
      );
      await loader.run();
      expect(loader.cancelled, isTrue);
      expect(n, 3);
    });

    test('手勢進行中讓路，放手才繼續', () async {
      var polls = 0;
      var n = 0;
      final order = <int>[];
      final loader = GifStripLoader(
        duration: 30,
        count: 4,
        refine: false,
        isBusy: () => ++polls <= 3,
        yieldWait: const Duration(milliseconds: 1),
        fetch: (t, {required tolMs}) async {
          n++;
          return _b(n);
        },
        onFrame: (i, _) => order.add(i),
      );
      await loader.run();
      expect(polls, greaterThan(3));
      expect(n, 4);
      expect(order, stripFillOrder(4));
    });

    test('長度 0 什麼都不抽', () async {
      var n = 0;
      final loader = GifStripLoader(
        duration: 0,
        count: 10,
        fetch: (t, {required tolMs}) async {
          n++;
          return _b(1);
        },
        onFrame: (_, _) {},
      );
      await loader.run();
      expect(n, 0);
    });
  });
}
