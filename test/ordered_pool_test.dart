// orderedPool：拼圖一批照片「照順序放、但同時解好幾張」的排程。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/ordered_pool.dart';

void main() {
  test('照順序交回；同時最多 window 個在做', () async {
    var running = 0;
    var peak = 0;
    final done = <int>[];
    // 後面的比前面的早做完，交回的順序還是照排
    final delays = [30, 5, 20, 1, 15, 2, 8];
    await orderedPool<String>(
      delays.length,
      window: 3,
      run: (i) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(Duration(milliseconds: delays[i]));
        running--;
        return 'p$i';
      },
      onResult: (i, v) {
        expect(v, 'p$i');
        done.add(i);
        return true;
      },
    );
    expect(done, [0, 1, 2, 3, 4, 5, 6]);
    expect(peak, 3);
  });

  test('window 1＝一個做完才開始下一個', () async {
    var running = 0;
    var peak = 0;
    await orderedPool<int>(
      5,
      window: 1,
      run: (i) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        running--;
        return i;
      },
      onResult: (_, _) => true,
    );
    expect(peak, 1);
  });

  test('丟例外的那一個交回 null，其他照常', () async {
    final got = <int, String?>{};
    await orderedPool<String>(
      4,
      window: 2,
      run: (i) async {
        if (i == 1) throw StateError('讀不出來');
        if (i == 2) return Future<String>.error(StateError('壞檔'));
        return 'ok$i';
      },
      onResult: (i, v) {
        got[i] = v;
        return true;
      },
    );
    expect(got, {0: 'ok0', 1: null, 2: null, 3: 'ok3'});
  });

  test('中途不要了：不再開新的，還在做的做完交給 discard', () async {
    final started = <int>[];
    final discarded = <String>[];
    final gates = List.generate(6, (_) => Completer<void>());
    final pool = orderedPool<String>(
      6,
      window: 3,
      run: (i) async {
        started.add(i);
        await gates[i].future;
        return 'p$i';
      },
      onResult: (i, v) => i < 1, // 收了第 0 張、第 1 張就說不要了
      discard: discarded.add,
    );
    gates[0].complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    for (final g in gates.skip(1)) {
      if (!g.isCompleted) g.complete();
    }
    await pool;
    await Future<void>.delayed(Duration.zero);
    // 每交一張之前先補滿（交出去的那一下也跟後面重疊）：交第 0 張前補了
    // 第 3 張、交第 1 張前補了第 4 張；第 1 張說不要之後不再開第 5 張，
    // 還在做的 2、3、4 做完交給 discard
    expect(started, [0, 1, 2, 3, 4]);
    expect(discarded..sort(), ['p2', 'p3', 'p4']);
  });

  test('沒有工作：直接結束', () async {
    var called = false;
    await orderedPool<int>(
      0,
      window: 3,
      run: (_) async {
        called = true;
        return 0;
      },
      onResult: (_, _) => true,
    );
    expect(called, isFalse);
  });
}
