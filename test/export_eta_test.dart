import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/export_eta.dart';

/// 可控時鐘：測試自己撥時間
class _Clock {
  DateTime now = DateTime(2026, 1, 1, 12);
  void tick(double sec) =>
      now = now.add(Duration(milliseconds: (sec * 1000).round()));
}

void main() {
  const p = ExportKind.photo, v = ExportKind.video;

  test('沒有樣本＝估算中；第一張做完就有數字', () {
    final c = _Clock();
    final eta = ExportEta(clock: () => c.now)..start();
    expect(eta.label(1, 4, p, [p, p, p]), '第 1 / 4 個 · 估算中…');
    c.tick(2);
    eta.itemDone(p);
    // 平均 2 秒，剩 3 張（目前這張剛開始）→ 6 秒
    expect(eta.remainingSec(p, [p, p]), 6);
    expect(eta.label(2, 4, p, [p, p]), '第 2 / 4 個 · 約還要 6 秒');
  });

  test('目前這張已經跑掉的時間會扣掉，扣到 0 為止', () {
    final c = _Clock();
    final eta = ExportEta(clock: () => c.now)..start();
    c.tick(2);
    eta.itemDone(p);
    c.tick(1.5); // 第二張已經跑了 1.5 秒
    expect(eta.rawRemaining(p, [p]), closeTo(2.5, 0.01));
    c.tick(5); // 第二張慢到超過平均：不會變負
    expect(eta.rawRemaining(p, [p]), closeTo(2, 0.01));
  });

  test('照片跟影片分開平均；後面排了沒樣本的類型就估算中', () {
    final c = _Clock();
    final eta = ExportEta(clock: () => c.now)..start();
    c.tick(1);
    eta.itemDone(p);
    // 目前照片、後面還有一部影片：影片沒樣本 → null
    expect(eta.remainingSec(p, [v]), isNull);
    c.tick(1);
    eta.itemDone(p);
    c.tick(30);
    eta.itemDone(v);
    // 平均：照片 1 秒、影片 30 秒；目前影片、後面一張照片＋一部影片
    expect(eta.rawRemaining(v, [p, v]), closeTo(61, 0.01));
  });

  test('影片進度百分比拿來算目前這部剩多少', () {
    final c = _Clock();
    final eta = ExportEta(clock: () => c.now)..start();
    c.tick(40);
    eta.itemDone(v);
    eta.noteProgress(0.75);
    expect(eta.rawRemaining(v, const []), closeTo(10, 0.01));
  });

  test('平滑：小幅往上不跳、繼續倒數；大幅才接受', () {
    final c = _Clock();
    final eta = ExportEta(clock: () => c.now)..start();
    c.tick(10);
    eta.itemDone(p);
    expect(eta.remainingSec(p, [p, p, p]), 40);
    c.tick(1);
    // 原始估計 39；讀數倒數也是 39
    expect(eta.remainingSec(p, [p, p, p]), 39);
    // 這張慢了：花 12 秒才好 → 平均 11，剩 3 張 → 33，比倒數（28）
    // 多 5 秒＝超過 max(3, 28*0.15=4.2) → 接受新估計
    c.tick(11);
    eta.itemDone(p);
    expect(eta.remainingSec(p, [p, p]), 33);
    // 下一張只慢一點：平均 11.33、剩 2 張 → 22.67；倒數到 33-12=21，
    // 只多 1.67 秒（≤3）→ 不跳，維持倒數
    c.tick(12);
    eta.itemDone(p);
    expect(eta.remainingSec(p, [p]), 21);
  });

  test('字串格式', () {
    expect(ExportEta.formatRemaining(null), '估算中…');
    expect(ExportEta.formatRemaining(0), '快好了');
    expect(ExportEta.formatRemaining(7), '約還要 7 秒');
    expect(ExportEta.formatRemaining(59), '約還要 59 秒');
    expect(ExportEta.formatRemaining(60), '約還要 1 分');
    expect(ExportEta.formatRemaining(125), '約還要 2 分 5 秒');
  });
}
