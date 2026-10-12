// 自由模式自動排版（collage_pack）的守門：
//
// - 一批混合比例的照片，五種畫布都要塞滿（≥90%）、不重疊、全在畫布內，
//   每一塊都是照片本來的形狀（拉滿時允許差 kCollagePackMaxStretch）
// - 同一組輸入同一個種子永遠排同一種；換種子就是另一種排法
// - 一兩張湊不出畫布比例時置中留邊，不裁掉照片一大塊
// - 30 張（上限）也排得快、壞資料不炸
// - 已經排好的再加照片（extendCollage，使用者回報「加入照片後會整個重新
//   排序原本的排列」）：原本並排的還是並排、左邊的還在左邊，上下疊的
//   上面的還在上面；加完一樣塞滿、不重疊、每塊是照片的形狀、新照片不會
//   被擠成看不見的小格。宮格抄過來（有空格）也拆得開；疊在一起的拆不開
//   回 null
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/collage_pack.dart';

/// 這批方塊蓋住畫布的比例（100×100 取樣，方塊可能重疊所以不能直接加面積）
double _coverage(List<ui.Rect> rs) {
  var hit = 0;
  for (var y = 0; y < 100; y++) {
    for (var x = 0; x < 100; x++) {
      final p = ui.Offset((x + 0.5) / 100, (y + 0.5) / 100);
      if (rs.any((r) => r.contains(p))) hit++;
    }
  }
  return hit / 10000;
}

/// 兩兩重疊的面積總和（畫布面積的比例）
double _overlap(List<ui.Rect> rs) {
  var sum = 0.0;
  for (var i = 0; i < rs.length; i++) {
    for (var j = i + 1; j < rs.length; j++) {
      final o = rs[i].intersect(rs[j]);
      if (o.width > 0 && o.height > 0) sum += o.width * o.height;
    }
  }
  return sum;
}

/// 方塊在畫布上的真實長寬比（比例座標要乘回畫布比例才是像素形狀）
double _pixelAspect(ui.Rect r, double canvas) => r.width * canvas / r.height;

/// 原本的排法沒被打散：[before] 裡並排（上下有重疊）的兩塊，左邊的在
/// [after] 還在左邊；上下疊（左右有重疊）的，上面的還在上面
void _expectSameArrangement(
  List<ui.Rect> before,
  List<ui.Rect> after,
  String why,
) {
  const e = 1e-6;
  for (var i = 0; i < before.length; i++) {
    for (var j = 0; j < before.length; j++) {
      if (i == j) continue;
      final a = before[i], b = before[j];
      final yOverlap = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
      final xOverlap = math.min(a.right, b.right) - math.max(a.left, b.left);
      if (yOverlap > e && a.right <= b.left + e) {
        expect(
          after[i].right,
          lessThanOrEqualTo(after[j].left + e),
          reason: '$why：第 $i 塊本來在第 $j 塊左邊',
        );
      }
      if (xOverlap > e && a.bottom <= b.top + e) {
        expect(
          after[i].bottom,
          lessThanOrEqualTo(after[j].top + e),
          reason: '$why：第 $i 塊本來在第 $j 塊上面',
        );
      }
    }
  }
}

/// 加完照片的版面：塞滿（≥[cover]）、不重疊、全在畫布內、每塊是照片的
/// 形狀；新的（[fresh] 之後）看得到：不小於平均大小的 0.15——原本就有
/// 一排小張的版面（使用者那種一大配一條小的）插進去本來就是小張那一級，
/// 那就跟原本最小的那張比，不小於它的一半
void _expectGoodExtend(
  List<ui.Rect> rs,
  List<double> aspects,
  int fresh,
  double canvas,
  String why, {
  double cover = 0.9,
}) {
  expect(rs.length, aspects.length, reason: why);
  expect(_coverage(rs), greaterThanOrEqualTo(cover), reason: '$why：要塞滿');
  expect(_overlap(rs), lessThan(1e-6), reason: '$why：不該重疊');
  final avg = rs.fold<double>(0, (s, r) => s + r.width * r.height) / rs.length;
  final oldMin = rs.take(fresh).map((r) => r.width * r.height).reduce(math.min);
  final floor = math.min(0.15 * avg, 0.5 * oldMin);
  for (var i = 0; i < rs.length; i++) {
    final r = rs[i];
    expect(r.left, greaterThanOrEqualTo(-1e-9), reason: '$why：第 $i 塊');
    expect(r.top, greaterThanOrEqualTo(-1e-9), reason: '$why：第 $i 塊');
    expect(r.right, lessThanOrEqualTo(1 + 1e-9), reason: '$why：第 $i 塊');
    expect(r.bottom, lessThanOrEqualTo(1 + 1e-9), reason: '$why：第 $i 塊');
    expect(
      _pixelAspect(r, canvas) / aspects[i],
      closeTo(1, kCollagePackMaxStretch),
      reason: '$why：第 $i 塊的形狀跑掉了',
    );
    if (i >= fresh) {
      expect(
        r.width * r.height,
        greaterThanOrEqualTo(floor),
        reason: '$why：新照片第 $i 塊小到看不清',
      );
    }
  }
}

const _canvases = [1.0, 0.8, 0.75, 16 / 9, 9 / 16];
const _photos = [1.5, 2 / 3, 1.0, 16 / 9, 9 / 16, 4 / 3];

void main() {
  test('六張混合比例：五種畫布都塞滿、不重疊、全在畫布內、每塊都是照片的形狀', () {
    for (final c in _canvases) {
      final rs = packCollage(_photos, c);
      expect(rs.length, _photos.length);
      expect(_coverage(rs), greaterThanOrEqualTo(0.9), reason: '畫布 $c 要塞滿');
      expect(_overlap(rs), lessThan(1e-6), reason: '畫布 $c 不該重疊');
      for (var i = 0; i < rs.length; i++) {
        final r = rs[i];
        expect(r.left, greaterThanOrEqualTo(-1e-9), reason: '畫布 $c 第 $i 塊');
        expect(r.top, greaterThanOrEqualTo(-1e-9), reason: '畫布 $c 第 $i 塊');
        expect(r.right, lessThanOrEqualTo(1 + 1e-9), reason: '畫布 $c 第 $i 塊');
        expect(r.bottom, lessThanOrEqualTo(1 + 1e-9), reason: '畫布 $c 第 $i 塊');
        expect(
          _pixelAspect(r, c) / _photos[i],
          closeTo(1, kCollagePackMaxStretch),
          reason: '畫布 $c 第 $i 塊的形狀跑掉了',
        );
      }
    }
  });

  test('同一組輸入同一個種子永遠排同一種；換種子是另一種排法', () {
    final a = packCollage(_photos, 1, seed: 3);
    final b = packCollage(_photos, 1, seed: 3);
    expect(a, b);
    final c = packCollage(_photos, 1, seed: 4);
    expect(c, isNot(equals(a)));
    // 換了種子還是要塞滿
    expect(_coverage(c), greaterThanOrEqualTo(0.9));
    expect(_overlap(c), lessThan(1e-6));
  });

  test('一張、兩張湊不出畫布比例：置中留邊、形狀一點都不動、不重疊', () {
    // 一張 3:2 放進 1:1：寬貼滿、上下留邊
    final one = packCollage(const [1.5], 1);
    expect(one.length, 1);
    expect(_pixelAspect(one[0], 1), closeTo(1.5, 1e-9));
    expect(one[0].width, closeTo(1, 1e-9));
    expect(one[0].center.dy, closeTo(0.5, 1e-9));
    // 兩張 4:3 放進 1:1：疊起來是 2:3，寬 2/3 置中，兩張都還是 4:3
    final two = packCollage(const [4 / 3, 4 / 3], 1);
    for (final r in two) {
      expect(_pixelAspect(r, 1), closeTo(4 / 3, 1e-9));
      expect(r.left, greaterThanOrEqualTo(-1e-9));
      expect(r.right, lessThanOrEqualTo(1 + 1e-9));
    }
    expect(_overlap(two), lessThan(1e-9));
    expect((two[0].left + two[0].right) / 2, closeTo(0.5, 1e-9));
    expect(_coverage(two), closeTo(2 / 3, 0.02));
  });

  test('30 張（上限）排得快；0／NaN 的比例當正方形不炸', () {
    final many = [for (var i = 0; i < 30; i++) i.isEven ? 4 / 3 : 3 / 4];
    final sw = Stopwatch()..start();
    final rs = packCollage(many, 9 / 16, seed: 7);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(1500));
    expect(rs.length, 30);
    expect(_coverage(rs), greaterThanOrEqualTo(0.9));
    expect(_overlap(rs), lessThan(1e-6));
    final bad = packCollage(const [0, double.nan, 1.5], 1);
    expect(bad.length, 3);
    expect(bad.every((r) => r.width > 0 && r.height > 0), isTrue);
    expect(packCollage(const [], 1), isEmpty);
  });

  group('已經排好的再加照片（extendCollage）', () {
    test('五種畫布、十種排法、加一到三張：不打散、塞滿、不重疊、照片形狀、新照片看得到', () {
      const base = [1.5, 2 / 3, 1.0, 16 / 9, 9 / 16];
      const more = [4 / 3, 9 / 16, 1.0];
      for (final c in _canvases) {
        for (var seed = 0; seed < 10; seed++) {
          final before = packCollage(base, c, seed: seed);
          for (var k = 1; k <= more.length; k++) {
            final add = more.sublist(0, k);
            final why = '畫布 $c 種子 $seed 加 $k 張';
            final after = extendCollage(before, base, add, c)!;
            _expectSameArrangement(before, after, why);
            _expectGoodExtend(after, [...base, ...add], base.length, c, why);
          }
        }
      }
    });

    test('使用者的版面：左邊一張大的、右邊一條直排四張——加一張之後大張還在左邊、直排上下順序不變', () {
      final before = [
        const ui.Rect.fromLTWH(0, 0, 0.82, 1),
        const ui.Rect.fromLTWH(0.82, 0, 0.18, 0.22),
        const ui.Rect.fromLTWH(0.82, 0.22, 0.18, 0.35),
        const ui.Rect.fromLTWH(0.82, 0.57, 0.18, 0.22),
        const ui.Rect.fromLTWH(0.82, 0.79, 0.18, 0.21),
      ];
      const aspects = [0.75, 9 / 16, 0.46, 9 / 16, 0.75];
      final after = extendCollage(before, aspects, const [0.75], 1)!;
      _expectSameArrangement(before, after, '加一張');
      _expectGoodExtend(after, [...aspects, 0.75], aspects.length, 1, '加一張');
      // 「大張在左邊」：右邊四張每一張都還在它右邊、彼此照原本的順序往下
      for (var i = 1; i < 5; i++) {
        expect(after[0].center.dx, lessThan(after[i].center.dx));
      }
      for (var i = 1; i < 4; i++) {
        expect(after[i].center.dy, lessThan(after[i + 1].center.dy));
      }
    });

    test('宮格抄過來（2×2 少一張、留一格空）也拆得開：不打散、補上那一格', () {
      final before = [
        const ui.Rect.fromLTWH(0, 0, 0.5, 0.5),
        const ui.Rect.fromLTWH(0.5, 0, 0.5, 0.5),
        const ui.Rect.fromLTWH(0, 0.5, 0.5, 0.5),
      ];
      final after = extendCollage(before, const [1, 1, 1], const [1], 1)!;
      _expectSameArrangement(before, after, '補一張');
      _expectGoodExtend(after, const [1, 1, 1, 1], 3, 1, '補一張', cover: 0.99);
    });

    test('疊在一起的、風車形的拆不出排法：回 null（交給呼叫端疊在上面）', () {
      final stacked = [
        const ui.Rect.fromLTWH(0, 0, 0.6, 0.6),
        const ui.Rect.fromLTWH(0.4, 0.4, 0.6, 0.6),
      ];
      expect(extendCollage(stacked, const [1, 1], const [1], 1), isNull);
      // 四塊繞著中間一格轉一圈：哪一刀都會切到某一塊
      final pinwheel = [
        const ui.Rect.fromLTWH(0, 0, 2 / 3, 1 / 3),
        const ui.Rect.fromLTWH(2 / 3, 0, 1 / 3, 2 / 3),
        const ui.Rect.fromLTWH(1 / 3, 2 / 3, 2 / 3, 1 / 3),
        const ui.Rect.fromLTWH(0, 1 / 3, 1 / 3, 2 / 3),
      ];
      expect(
        extendCollage(pinwheel, const [2, 0.5, 2, 0.5], const [1], 1),
        isNull,
      );
    });

    test('一次加很多張也快（30 張上限）；壞資料不炸；畫布上沒東西就照常排', () {
      final one = packCollage(const [4 / 3], 9 / 16);
      final add = [for (var i = 0; i < 29; i++) i.isEven ? 3 / 4 : 4 / 3];
      final sw = Stopwatch()..start();
      final rs = extendCollage(one, const [4 / 3], add, 9 / 16)!;
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1500));
      expect(rs.length, 30);
      expect(_overlap(rs), lessThan(1e-6));
      final bad = extendCollage(
        packCollage(const [1.5, 1], 1),
        const [1.5, 1],
        const [0, double.nan],
        1,
      )!;
      expect(bad.length, 4);
      expect(bad.every((r) => r.width > 0 && r.height > 0), isTrue);
      expect(
        extendCollage(const [], const [], const [1.5, 1], 1),
        packCollage(const [1.5, 1], 1),
      );
    });
  });
}
