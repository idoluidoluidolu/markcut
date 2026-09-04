// 匯入的「約還要多久」（ImportEta）。
//
// 匯出那顆（ExportEta）算的是「一個項目平均要多久」；匯入不能那樣算——
// 一支 5 秒的素材跟一支 3 分鐘的素材差 36 倍。這裡估的是
// 「剩下的素材秒數 ÷ 倍速」，倍速從轉檔本身量（轉完的樣本，或還在轉的
// 那支的進度回報）。守的就是那三段：估算中 → 進度回報量到 → 轉完的樣本
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/export_eta.dart';

/// 可控時鐘：測試自己撥時間
class _Clock {
  DateTime now = DateTime(2026, 1, 1, 12);
  void tick(double sec) =>
      now = now.add(Duration(milliseconds: (sec * 1000).round()));
}

void main() {
  setUp(ImportEta.resetLearnedTail);
  tearDown(ImportEta.resetLearnedTail);

  test('一支都還沒轉完、也還沒有進度＝估算中', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 2)..start();
    eta.itemStart(60);
    expect(eta.speed, isNull);
    expect(eta.remainingSec(srcSecLeft: 60, itemsLeft: 1), isNull);
    expect(
      eta.label(index1: 1, total: 3, srcSecLeft: 60, itemsLeft: 3),
      '第 1 / 3 支 · 估算中…',
    );
  });

  test('第一支的進度回報就量得到倍速（不用等它轉完）', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 2, perItemSec: 0)
      ..start();
    eta.itemStart(60);
    // 開檔那一秒還沒有影格：不夠久，不算
    c.tick(1);
    eta.noteProgress(0.05);
    expect(eta.speed, isNull);
    // 4 秒轉掉 16 秒的素材＝4 倍速
    c.tick(3);
    eta.noteProgress(16 / 60);
    expect(eta.speed, closeTo(4, 0.01));
    // 剩 60-16＝44 秒的素材 ÷ 4 倍速＝11 秒，加尾巴 2 秒
    expect(
      eta.rawRemaining(srcSecLeft: 60, itemsLeft: 1),
      closeTo(13, 0.01),
    );
  });

  test('轉完的樣本是整批平均（長片權重大），而且蓋過進度那個估計', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 0, perItemSec: 0)
      ..start();
    eta.itemStart(30);
    c.tick(10); // 30 秒素材花 10 秒＝3 倍速
    eta.itemDone();
    expect(eta.speed, closeTo(3, 0.01));
    eta.itemStart(90);
    c.tick(20); // 90 秒素材花 20 秒；合計 120 秒 ÷ 30 秒＝4 倍速
    eta.itemDone();
    expect(eta.speed, closeTo(4, 0.01));
    // 剩兩支共 120 秒 ÷ 4＝30 秒
    expect(
      eta.rawRemaining(srcSecLeft: 120, itemsLeft: 2),
      closeTo(30, 0.01),
    );
  });

  test('正在轉的那一支：進度扣掉的是它自己的秒數', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 0, perItemSec: 0)
      ..start();
    eta.itemStart(20);
    c.tick(10); // 2 倍速
    eta.itemDone();
    // 第二支 40 秒，轉一半：剩下 20（它）＋30（第三支）＝50 ÷ 2＝25
    eta.itemStart(40);
    eta.noteProgress(0.5);
    expect(
      eta.rawRemaining(srcSecLeft: 70, itemsLeft: 2),
      closeTo(25, 0.01),
    );
  });

  test('「免轉直用」那種一秒內就回來的不當樣本（不然下一支會說快好了）', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 0, perItemSec: 0)
      ..start();
    eta.itemStart(30);
    c.tick(0.1); // 純檔案複製：300 倍速
    eta.itemDone();
    expect(eta.speed, isNull, reason: '這種樣本要丟掉，不是拿來估倍速的');
    // 真的轉一支才有數字
    eta.itemStart(30);
    c.tick(10);
    eta.itemDone();
    expect(eta.speed, closeTo(3, 0.01));
  });

  test('倍速有上限：不會因為某一支特別快就說剩下的都快好了', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 0, perItemSec: 0)
      ..start();
    eta.itemStart(300);
    c.tick(1); // 300 倍速
    eta.itemDone();
    expect(eta.speed, 15.0);
    expect(
      eta.rawRemaining(srcSecLeft: 300, itemsLeft: 1),
      closeTo(20, 0.01),
    );
  });

  test('尾巴：轉檔全做完之後讀數不會停在「快好了」，會把組合成倒數完', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 3, perItemSec: 0)
      ..start();
    eta.itemStart(20);
    c.tick(10);
    eta.itemDone();
    // 沒有素材要轉了：剩下的就是尾巴（不需要倍速也答得出來）
    expect(eta.remainingSec(srcSecLeft: 0, itemsLeft: 0), 3);
    eta.composing();
    c.tick(2);
    expect(eta.remainingSec(srcSecLeft: 0, itemsLeft: 0), 1);
    c.tick(2);
    expect(
      eta.remainingText(srcSecLeft: 0, itemsLeft: 0),
      '快好了',
    );
  });

  test('沒有樣本、也還沒開始轉：尾巴照樣答得出來（不會卡在估算中）', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 2)..start();
    expect(eta.remainingSec(srcSecLeft: 0, itemsLeft: 0), 2);
  });

  test('平滑：小幅往上不跳、繼續倒數；大幅才接受', () {
    final c = _Clock();
    final eta = ImportEta(clock: () => c.now, tailSec: 0, perItemSec: 0)
      ..start();
    eta.itemStart(100);
    c.tick(10); // 10 倍速
    eta.itemDone();
    expect(eta.remainingSec(srcSecLeft: 400, itemsLeft: 4), 40);
    c.tick(1);
    expect(eta.remainingSec(srcSecLeft: 400, itemsLeft: 4), 39);
    // 這支慢了（100 秒素材花 40 秒）：合計 200÷50＝4 倍速，
    // 剩 300 秒素材＝75 秒，比倒數（39-40<0）多很多 → 接受
    eta.itemStart(100);
    c.tick(40);
    eta.itemDone();
    expect(eta.remainingSec(srcSecLeft: 300, itemsLeft: 3), 75);
  });

  test('學到的尾巴：這一趟組合成花多久，下一趟就用那個數字', () {
    expect(ImportEta().tailSec, 2.0);
    ImportEta.noteTailSec(6); // (2+6)/2
    expect(ImportEta().tailSec, 4.0);
    ImportEta.noteTailSec(0); // 下限 0.3：(4+0.3)/2
    expect(ImportEta().tailSec, closeTo(2.15, 0.001));
    ImportEta.noteTailSec(double.nan); // 壞數字不理
    expect(ImportEta().tailSec, closeTo(2.15, 0.001));
  });

  test('字串格式跟匯出同一套', () {
    expect(ImportEta.formatRemaining(null), '估算中…');
    expect(ImportEta.formatRemaining(0), '快好了');
    expect(ImportEta.formatRemaining(45), '約還要 45 秒');
    expect(ImportEta.formatRemaining(125), '約還要 2 分 5 秒');
    expect(
      ImportEta.formatRemaining(60),
      ExportEta.formatRemaining(60),
      reason: '兩邊共用同一個說法',
    );
  });
}
