// OverlaySync 狀態機的時序體檢（testWidgets 的假時鐘＋注入的 now）：
// 1. 閒置後第一次變更不等併批：下一輪事件迴圈就起烘
// 2. 全解析在途時內容又變：退到背景，新內容的快路立刻起烘、不被擋；
//    退到背景那版烘完不會蓋掉螢幕上更新的內容
// 3. gestureActive 期間不起烘全解析（拖到一半停手半秒也不會）；
//    放手後補一版
// 4. 合成重建帶著最新版（reset）之後，在途的快路版本不會倒退上屏
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/overlay_sync.dart';

class _Rig {
  _Rig({this.fastMs = 10, this.fullMs = 300});

  final int fastMs;
  final int fullMs;
  String sig = 'a';
  bool gesture = false;
  bool on = true;
  DateTime t = DateTime(2026, 1, 1);
  final List<(String, bool)> baked = [];
  final List<(String, bool)> applied = [];

  late final OverlaySync sync = OverlaySync(
    enabled: () => on,
    signature: () => sig,
    gestureActive: () => gesture,
    now: () => t,
    bake: (s, fast) async {
      baked.add((s, fast));
      await Future<void>.delayed(
        Duration(milliseconds: fast ? fastMs : fullMs),
      );
      return [
        {'sig': s, 'fast': fast},
      ];
    },
    apply: (maps, s, fast) async {
      applied.add((s, fast));
      return true;
    },
  );

  /// 假時鐘一格一格走（計時器到期時看到的 now 跟走過的時間一致）
  Future<void> elapse(WidgetTester tester, int ms, {int step = 5}) async {
    var left = ms;
    while (left > 0) {
      final d = left < step ? left : step;
      t = t.add(Duration(milliseconds: d));
      await tester.pump(Duration(milliseconds: d));
      left -= d;
    }
  }

  /// 只跑到期的零延遲計時器與微任務（不走時間）
  Future<void> turn(WidgetTester tester) => tester.pump(Duration.zero);
}

void main() {
  testWidgets('閒置後第一次變更不等併批：下一輪就起烘、烘完就上屏', (
    tester,
  ) async {
    final r = _Rig();
    r.sync.request();
    expect(r.baked, isEmpty); // request 本身只排計時器
    await r.turn(tester);
    expect(r.baked, [('a', true)]); // 0ms 後就起烘（快路先上）
    await r.elapse(tester, r.fastMs);
    expect(r.applied, [('a', true)]);
    // 停穩 quietMs 後恰好補一版全解析
    await r.elapse(tester, 600);
    expect(r.baked.last, ('a', false));
    await r.elapse(tester, r.fullMs + 50);
    expect(r.applied.last, ('a', false));
    expect(r.applied.length, 2);
    r.sync.dispose();
  });

  testWidgets('全解析在途時點了別格：退到背景，新格的快路立刻起烘', (
    tester,
  ) async {
    final r = _Rig();
    r.sync.request();
    await r.turn(tester);
    await r.elapse(tester, r.fastMs);
    expect(r.applied, [('a', true)]);
    // 停穩 → 全解析起烘（300ms）
    await r.elapse(tester, 600);
    expect(r.baked.last, ('a', false));
    // 全解析烘到一半，使用者點了另一格
    await r.elapse(tester, 100);
    r.sig = 'b';
    r.sync.request();
    await r.turn(tester);
    expect(r.baked.last, ('b', true), reason: '快路不該等全解析烘完');
    expect(r.sync.demoted, 1);
    await r.elapse(tester, r.fastMs);
    expect(r.applied.last, ('b', true));
    // 背景那版 a 全解析烘完：比螢幕上的舊，丟掉（不能閃回 a）
    await r.elapse(tester, r.fullMs);
    expect(r.applied.where((e) => e.$1 == 'a').length, 1);
    expect(r.sync.dropped, 1);
    // 停穩後補 b 的全解析
    await r.elapse(tester, 600 + r.fullMs);
    expect(r.applied.last, ('b', false));
    expect(r.sync.appliedSig, 'b');
    expect(r.sync.appliedFast, isFalse);
    r.sync.dispose();
  });

  testWidgets('滑桿按著：停手半秒也不起烘全解析，放手才補', (tester) async {
    final r = _Rig();
    r.gesture = true;
    r.sync.request();
    await r.turn(tester);
    await r.elapse(tester, r.fastMs);
    expect(r.applied, [('a', true)]);
    // 手指停著 2 秒：沒有任何全解析起烘
    await r.elapse(tester, 2000);
    expect(r.baked.every((e) => e.$2), isTrue);
    // 停手後再動：還是快路
    r.sig = 'b';
    r.sync.request();
    await r.turn(tester);
    expect(r.baked.last, ('b', true));
    await r.elapse(tester, r.fastMs);
    // 放手：一版全解析
    r.gesture = false;
    r.sync.request();
    await r.turn(tester);
    await r.elapse(tester, 600 + r.fullMs);
    expect(r.applied.last, ('b', false));
    expect(r.baked.where((e) => !e.$2).length, 1);
    r.sync.dispose();
  });

  testWidgets('連續變更：快路兩版之間至少 minGapMs、烘完立刻追最新', (
    tester,
  ) async {
    final r = _Rig(fastMs: 30);
    r.gesture = true;
    for (var i = 0; i < 20; i++) {
      r.sig = 's$i';
      r.sync.request();
      await r.elapse(tester, 16, step: 16);
    }
    // 320ms 內：80ms 一版節拍 → 4~5 版，不會每一格都烘
    expect(r.baked.length, inInclusiveRange(3, 5));
    r.gesture = false;
    r.sync.request();
    await r.elapse(tester, 1000);
    // 最後一定追到最新內容，且以全解析收尾
    expect(r.applied.last, ('s19', false));
    expect(r.sync.appliedSig, 's19');
    r.sync.dispose();
  });

  testWidgets('合成重建帶著最新版：在途的快路版本不會倒退上屏', (
    tester,
  ) async {
    final r = _Rig(fastMs: 50);
    r.sync.request();
    await r.turn(tester);
    expect(r.baked, [('a', true)]);
    // 快路烘到一半，重建完成的合成已經把 a（全解析）烘進去了
    await r.elapse(tester, 20);
    r.sync.reset(appliedSig: 'a');
    r.sync.request();
    await r.elapse(tester, 100);
    // 快路那版比合成帶的還差（半解析），照樣不能蓋上去
    expect(r.applied, isEmpty);
    expect(r.sync.appliedSig, 'a');
    expect(r.sync.appliedFast, isFalse);
    await r.elapse(tester, 1000);
    expect(r.baked.length, 1, reason: '沒有新內容就不該再烘');
    r.sync.dispose();
  });

  testWidgets('flush 等背景全解析也烘完，最後以全解析上屏最新版', (
    tester,
  ) async {
    final r = _Rig(fullMs: 200);
    r.sync.request();
    await r.turn(tester);
    await r.elapse(tester, r.fastMs + 600); // a 快路上屏、a 全解析起烘
    r.sig = 'b';
    r.sync.request();
    await r.turn(tester); // a 全解析退背景、b 快路起烘
    var done = false;
    unawaited(r.sync.flush().then((_) => done = true));
    await r.elapse(tester, 2000);
    expect(done, isTrue);
    expect(r.applied.last, ('b', false));
    r.sync.dispose();
  });
}
