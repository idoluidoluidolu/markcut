// 影片自動碼臉的核心：一格一格的偵測結果 → 每個人一條軌跡。
//
// 守的是：
//   1. 兩個人交錯走過：照速度推算，不會在交會時換人
//   2. 轉頭、被擋一下（maxGap 內）還是同一個人，空檔用內插補上
//   3. 消失太久再出現＝新的一個人
//   4. 只出現一次的（誤判）丟掉
//   5. 頭尾各多蓋一點（不超出影片長度、不早於 0）
//   6. 去抖：框一格一格跳的時候，軌跡比原始偵測平順
//   7. at(t)：兩點之間照時間內插；軌跡外回 null
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/face_detect.dart';
import 'package:markcut/services/face_tracks.dart';

/// 每 0.1 秒一格，[from]～[to] 秒
List<double> _times(double from, double to) => [
  for (var i = 0; (from + i * 0.1) <= to + 1e-9; i++)
    double.parse((from + i * 0.1).toStringAsFixed(3)),
];

FaceBox _box(double cx, double cy, [double w = 0.12, double h = 0.16]) =>
    FaceBox(cx - w / 2, cy - h / 2, w, h);

void main() {
  test('兩個人交錯走過：交會時不換人', () {
    final samples = [
      for (final t in _times(0, 3))
        FaceSample(t, [
          _box(0.1 + 0.2 * t, 0.4), // A：往右
          _box(0.7 - 0.2 * t, 0.42), // B：往左
        ]),
    ];
    final tracks = buildFaceTracks(samples);
    expect(tracks.length, 2);
    final a = tracks.firstWhere((tr) => tr.at(0.2)!.cx < 0.4);
    final b = tracks.firstWhere((tr) => tr != a);
    expect(a.at(2.9)!.cx, greaterThan(0.6), reason: 'A 交會後被換成 B 了');
    expect(b.at(2.9)!.cx, lessThan(0.2), reason: 'B 交會後被換成 A 了');
  });

  test('轉頭／被擋一下（1 秒內）還是同一個人，空檔補上', () {
    final samples = [
      for (final t in _times(0, 1.0)) FaceSample(t, [_box(0.5, 0.4)]),
      for (final t in _times(1.1, 1.5)) FaceSample(t, const []),
      for (final t in _times(1.6, 3.0)) FaceSample(t, [_box(0.52, 0.4)]),
    ];
    final tracks = buildFaceTracks(samples);
    expect(tracks.length, 1, reason: '同一個人被拆成兩段，中間會露臉');
    final mid = tracks.single.at(1.3);
    expect(mid, isNotNull, reason: '空檔那幾格沒有蓋');
    expect(mid!.cx, closeTo(0.51, 0.02));
  });

  test('消失太久（超過 1 秒）再出現＝另一個人', () {
    final samples = [
      for (final t in _times(0, 1.0)) FaceSample(t, [_box(0.5, 0.4)]),
      for (final t in _times(2.5, 3.5)) FaceSample(t, [_box(0.5, 0.4)]),
    ];
    final tracks = buildFaceTracks(samples);
    expect(tracks.length, 2);
    expect(tracks[0].id, 1);
    expect(tracks[1].id, 2);
    expect(tracks[0].at(1.8), isNull, reason: '不在的時候不該蓋');
  });

  test('只出現一次的（誤判）丟掉', () {
    final samples = [
      for (final t in _times(0, 2)) FaceSample(t, [_box(0.3, 0.4)]),
      const FaceSample(0.7, []),
    ];
    // 0.9 秒那一格多一個遠處的框
    samples.add(FaceSample(0.95, [_box(0.3, 0.4), _box(0.85, 0.2)]));
    final tracks = buildFaceTracks(samples);
    expect(tracks.length, 1, reason: '只出現一次的框不該變成一個人');
  });

  test('頭尾各多蓋一點，不早於 0、不超出影片長度', () {
    final samples = [
      for (final t in _times(0.1, 1.9)) FaceSample(t, [_box(0.5, 0.5)]),
    ];
    final tr = buildFaceTracks(samples, duration: 2.0).single;
    expect(tr.start, closeTo(0.0, 1e-9), reason: '往前多蓋 0.2 秒，但不早於 0');
    expect(tr.end, closeTo(2.0, 1e-9), reason: '往後多蓋 0.3 秒，但不超出影片');
    expect(tr.at(0.0), isNotNull);
  });

  test('去抖：框一格一格跳的時候，軌跡比原始偵測平順', () {
    final raw = <double>[];
    final samples = <FaceSample>[];
    for (final (i, t) in _times(0, 2).indexed) {
      final cx = 0.5 + (i.isEven ? 0.012 : -0.012);
      raw.add(cx);
      samples.add(FaceSample(t, [_box(cx, 0.4)]));
    }
    final tr = buildFaceTracks(samples).single;
    double jitter(List<double> v) {
      var s = 0.0;
      for (var i = 1; i < v.length; i++) {
        s += (v[i] - v[i - 1]).abs();
      }
      return s;
    }

    final smooth = [for (final t in _times(0, 2)) tr.at(t)!.cx];
    expect(jitter(smooth), lessThan(jitter(raw) * 0.6));
  });

  test('蓋的範圍：比偵測框大一圈、中心往上挪', () {
    final samples = [
      for (final t in _times(0, 1)) FaceSample(t, [_box(0.5, 0.5, 0.1, 0.2)]),
    ];
    final k = buildFaceTracks(samples).single.at(0.5)!;
    expect(k.w, closeTo(0.13, 1e-9));
    expect(k.h, closeTo(0.29, 1e-9));
    expect(k.cy, closeTo(0.5 - 0.016, 1e-9));
  });

  test('at(t)：兩點之間照時間內插；軌跡外回 null', () {
    final tr = FaceTrack(1, const [
      FaceKey(1, 0.2, 0.4, 0.1, 0.1),
      FaceKey(2, 0.6, 0.4, 0.3, 0.1),
    ], const FaceKey(2, 0.6, 0.4, 0.3, 0.1));
    final k = tr.at(1.5)!;
    expect(k.cx, closeTo(0.4, 1e-9));
    expect(k.w, closeTo(0.2, 1e-9));
    expect(tr.at(0.9), isNull);
    expect(tr.at(2.1), isNull);
  });
}
