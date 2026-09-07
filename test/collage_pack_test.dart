// 自由模式自動排版（collage_pack）的守門：
//
// - 一批混合比例的照片，五種畫布都要塞滿（≥90%）、不重疊、全在畫布內，
//   每一塊都是照片本來的形狀（拉滿時允許差 kCollagePackMaxStretch）
// - 同一組輸入同一個種子永遠排同一種；換種子就是另一種排法
// - 一兩張湊不出畫布比例時置中留邊，不裁掉照片一大塊
// - 30 張（上限）也排得快、壞資料不炸
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
}
