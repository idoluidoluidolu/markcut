// 會動的馬賽克（影片自動找臉）的關鍵點規則：
//   1. 位置在兩點之間照時間內插；大小沿用前一點那一段（不內插）
//   2. 頭尾外面回 null（容許半格的捨入誤差）
//   3. 差不多大的連續幾點併成同一個大小，取最大的；差太多就換一段
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/mosaic.dart';

void main() {
  test('位置內插、大小沿用前一點', () {
    final keys = [
      1.0, 0.2, 0.4, 0.10, 0.20, //
      2.0, 0.6, 0.4, 0.30, 0.40,
    ];
    final p = mosaicPathAt(keys, 1.5)!;
    expect(p.cx, closeTo(0.4, 1e-9));
    expect(p.cy, closeTo(0.4, 1e-9));
    expect(p.w, 0.10, reason: '大小不內插：FFmpeg 一段只能有一個大小');
    expect(p.h, 0.20);
    expect(mosaicPathAt(keys, 2.0)!.w, 0.30);
  });

  test('頭尾外面回 null，半格以內的捨入照樣碼', () {
    final keys = [1.0, 0.5, 0.5, 0.1, 0.1, 2.0, 0.5, 0.5, 0.1, 0.1];
    expect(mosaicPathAt(keys, 0.9), isNull);
    expect(mosaicPathAt(keys, 2.1), isNull);
    expect(mosaicPathAt(keys, 1.0 - 0.01), isNotNull);
    expect(mosaicPathAt(keys, 2.0 + 0.01), isNotNull);
    expect(mosaicPathAt(const [], 1), isNull);
  });

  test('差不多大的併成一段（取最大）；差太多換一段', () {
    final keys = [
      0.0, 0.5, 0.5, 0.100, 0.200, //
      0.1, 0.5, 0.5, 0.105, 0.210,
      0.2, 0.5, 0.5, 0.110, 0.205,
      0.3, 0.5, 0.5, 0.200, 0.400, // 一下子變兩倍：人走近了
      0.4, 0.5, 0.5, 0.210, 0.410,
    ];
    final q = quantizeMosaicPath(keys);
    List<double> sizes(int i) => [q[i * 5 + 3], q[i * 5 + 4]];
    expect(sizes(0), [0.110, 0.210]);
    expect(sizes(1), [0.110, 0.210]);
    expect(sizes(2), [0.110, 0.210]);
    expect(sizes(3), [0.210, 0.410]);
    expect(sizes(4), [0.210, 0.410]);
    expect(keys[3], 0.100, reason: '不能動到傳進來的那一串');
    // 時間跟位置不動
    for (var i = 0; i < 5; i++) {
      expect(q[i * 5], keys[i * 5]);
      expect(q[i * 5 + 1], keys[i * 5 + 1]);
    }
  });
}
