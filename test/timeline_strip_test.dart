// 進場閘門的粗縮圖帶（見 timeline_strip.dart）：
// - 容忍值＝半格但至少 1 秒
// - 每格照原生回報的 actualSeconds 放，空格借最近的一格，順序不會亂
// - 截止時間到了／頁面關了就停，已抽到的照樣鋪成一整條
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/native_frames.dart';
import 'package:markcut/services/timeline_strip.dart';

/// 一格的假畫面：位元組就是它的秒數（整數），方便驗證放到哪一格
Uint8List _frame(int seconds) => Uint8List.fromList([seconds]);

void main() {
  group('coarseStripTolMs', () {
    test('長片：半格寬（48 秒十格＝2.4 秒）', () {
      expect(coarseStripTolMs(48, 10), 2400);
    });
    test('短片：半格不到 1 秒就取 1 秒（GOP 最長約 1 秒）', () {
      expect(coarseStripTolMs(2, 10), 1000);
      expect(coarseStripTolMs(19.9, 10), 1000);
      expect(coarseStripTolMs(20.2, 10), 1010);
    });
    test('壞輸入不會爆', () {
      expect(coarseStripTolMs(0, 10), 1000);
      expect(coarseStripTolMs(double.nan, 10), 1000);
      expect(coarseStripTolMs(10, 0), 1000);
    });
  });

  group('coarseCellIndex', () {
    test('落在自己那格，邊界夾住', () {
      expect(coarseCellIndex(0, 10, 10), 0);
      expect(coarseCellIndex(0.99, 10, 10), 0);
      expect(coarseCellIndex(1.0, 10, 10), 1);
      expect(coarseCellIndex(9.99, 10, 10), 9);
      expect(coarseCellIndex(10, 10, 10), 9);
      expect(coarseCellIndex(-1, 10, 10), 0);
    });
  });

  group('fillStripGaps', () {
    test('空格借最近的一格', () {
      final out = fillStripGaps([null, _frame(1), null, null, _frame(4)]);
      expect(out.map((b) => b[0]), [1, 1, 1, 4, 4]);
    });
    test('一格都沒有就是空清單', () {
      expect(fillStripGaps([null, null]), isEmpty);
    });
  });

  group('loadCoarseStrip', () {
    test('原生回的時間就是要的時間：十格照順序', () async {
      final out = await loadCoarseStrip(
        duration: 10,
        count: 10,
        fetch: (t, tol) async =>
            NativeFrameSample(bytes: _frame(t.floor()), actualSeconds: t),
      );
      expect(out.length, 10);
      expect(out.map((b) => b[0]), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('關鍵幀貼齊：每格照實際時間放、相鄰格共用同一個關鍵幀、順序不亂', () async {
      // 30 秒、關鍵幀每 4 秒一個（0,4,8,…,28）：要 t 就回最近的關鍵幀
      double snap(double t) => (t / 4).round() * 4.0;
      final out = await loadCoarseStrip(
        duration: 30,
        count: 10,
        fetch: (t, tol) async {
          final k = snap(t).clamp(0.0, 28.0);
          return NativeFrameSample(bytes: _frame(k.round()), actualSeconds: k);
        },
      );
      expect(out.length, 10);
      final secs = out.map((b) => b[0]).toList();
      // 單調不減：畫面順序跟時間軸一致
      for (var i = 1; i < secs.length; i++) {
        expect(secs[i], greaterThanOrEqualTo(secs[i - 1]), reason: '$secs');
      }
      // 每一格畫的都是「那一段附近」真的存在的關鍵幀（差不超過一格＋4 秒）
      for (var i = 0; i < secs.length; i++) {
        final center = 30 * (i + 0.5) / 10;
        expect(
          (secs[i] - center).abs(),
          lessThanOrEqualTo(3 + 4),
          reason: '格 $i',
        );
      }
    });

    test('截止時間到了就停，已抽到的鋪滿整條', () async {
      // 假時鐘：每抽一格走 10ms，截止 25ms → 第三格抽完就過期
      var clock = DateTime(2026, 1, 1);
      var calls = 0;
      final out = await loadCoarseStrip(
        duration: 10,
        count: 10,
        deadline: clock.add(const Duration(milliseconds: 25)),
        now: () => clock,
        fetch: (t, tol) async {
          calls++;
          clock = clock.add(const Duration(milliseconds: 10));
          return NativeFrameSample(bytes: _frame(t.floor()), actualSeconds: t);
        },
      );
      expect(calls, 3);
      expect(out.length, 10, reason: '被截斷也要鋪成一整條');
      // 二分順序先抽頭、尾、中：借出去的都是這三格
      expect(out.map((b) => b[0]).toSet(), {0, 9, 4});
    });

    test('這一格太慢：剩餘預算的 timeout 把它砍掉，當抽不到', () async {
      var calls = 0;
      final out = await loadCoarseStrip(
        duration: 10,
        count: 10,
        deadline: DateTime.now().add(const Duration(milliseconds: 40)),
        fetch: (t, tol) async {
          calls++;
          // 第二格永遠不回：逾時後截止也過了，整條只有第一格
          if (calls == 2) await Completer<void>().future;
          return NativeFrameSample(bytes: _frame(t.floor()), actualSeconds: t);
        },
      );
      expect(calls, 2);
      expect(out.length, 10);
      expect(out.map((b) => b[0]).toSet(), {0});
    });

    test('原生永遠不回：截止時間一到照樣放行，不會卡住閘門', () async {
      final sw = Stopwatch()..start();
      final out = await loadCoarseStrip(
        duration: 10,
        count: 10,
        deadline: DateTime.now().add(const Duration(milliseconds: 50)),
        // 永遠不完成的 Future
        fetch: (t, tol) => Completer<NativeFrameSample?>().future,
      );
      expect(out, isEmpty);
      expect(sw.elapsedMilliseconds, lessThan(1000), reason: '要在預算附近就回來');
    });

    test('頁面關了就停', () async {
      var calls = 0;
      final out = await loadCoarseStrip(
        duration: 10,
        count: 10,
        alive: () => calls < 2,
        fetch: (t, tol) async {
          calls++;
          return NativeFrameSample(bytes: _frame(t.floor()), actualSeconds: t);
        },
      );
      expect(calls, 2);
      expect(out.length, 10);
    });

    test('抽不到的格子借鄰居；全部抽不到回空', () async {
      final some = await loadCoarseStrip(
        duration: 10,
        count: 4,
        fetch: (t, tol) async => t < 5
            ? null
            : NativeFrameSample(bytes: _frame(t.floor()), actualSeconds: t),
      );
      expect(some.length, 4);
      expect(some.map((b) => b[0]), [6, 6, 6, 8]);
      final none = await loadCoarseStrip(
        duration: 10,
        count: 4,
        fetch: (t, tol) async => null,
      );
      expect(none, isEmpty);
    });

    test('舊原生端不回 actualSeconds：照要的那格放', () async {
      final out = await loadCoarseStrip(
        duration: 10,
        count: 5,
        fetch: (t, tol) async => NativeFrameSample(bytes: _frame(t.floor())),
      );
      expect(out.map((b) => b[0]), [1, 3, 5, 7, 9]);
    });

    test('容忍值照 coarseStripTolMs 給', () async {
      final seen = <int>{};
      await loadCoarseStrip(
        duration: 48,
        count: 10,
        fetch: (t, tol) async {
          seen.add(tol);
          return null;
        },
      );
      expect(seen, {2400});
    });
  });
}
