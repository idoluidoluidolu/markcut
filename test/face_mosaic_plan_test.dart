// 找臉軌跡（影片素材秒數、轉正後的畫面 0~1）→ 時間軸上一塊會動的馬賽克：
//   1. 時間：素材秒數 → 時間軸秒數（修剪、片段起點、變速）
//   2. 位置：影片等比塞進畫布（直式畫布上下留黑也對）、鏡像左右翻
//   3. 片段播不到的那一段丟掉；整個人都不在片段裡就不建
//   4. 轉了 90 度：中心跟著轉、寬高對調
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/face_mosaic_plan.dart';
import 'package:markcut/services/face_tracks.dart';

FaceTrack _track(List<(double, double, double, double, double)> ks) {
  final keys = [for (final k in ks) FaceKey(k.$1, k.$2, k.$3, k.$4, k.$5)];
  return FaceTrack(1, keys, keys.first);
}

TimelineClip _video({
  double offset = 0,
  double trimStart = 0,
  double trimEnd = 10,
  double speed = 1,
  bool mirror = false,
  double rotation = 0,
}) => TimelineClip(
  id: 1,
  sourceIndex: 0,
  trimStart: trimStart,
  trimEnd: trimEnd,
  offset: offset,
  track: 0,
  speed: speed,
  mirror: mirror,
  rotation: rotation,
);

void main() {
  test('時間換算：片段起點、修剪', () {
    final plans = planFaceMosaics(
      [
        _track([(1.5, 0.5, 0.5, 0.1, 0.2), (2.5, 0.5, 0.5, 0.1, 0.2)]),
      ],
      _video(offset: 2, trimStart: 1, trimEnd: 6),
      16 / 9,
      16 / 9,
    );
    final p = plans.single;
    expect(p.offset, closeTo(2.5, 1e-9), reason: '素材 1.5 秒＝時間軸 2+0.5');
    expect(p.length, closeTo(1.0, 1e-9));
    expect(p.path[0], 0, reason: '關鍵點時間從 0 起算');
    expect(p.path[5], closeTo(1.0, 1e-9));
    expect(p.path.sublist(1, 5), [0.5, 0.5, 0.1, 0.2]);
  });

  test('變速 2 倍：時間軸上的長度減半', () {
    final p = planFaceMosaics(
      [
        _track([(0, 0.5, 0.5, 0.1, 0.1), (2, 0.5, 0.5, 0.1, 0.1)]),
      ],
      _video(speed: 2),
      1,
      1,
    ).single;
    expect(p.length, closeTo(1.0, 1e-9));
  });

  test('橫的影片放進直式畫布：上下留黑，臉照比例縮', () {
    final p = planFaceMosaics(
      [
        _track([(0, 0.5, 0.5, 0.1, 0.2), (1, 0.5, 0.25, 0.1, 0.2)]),
      ],
      _video(),
      16 / 9,
      9 / 16,
    ).single;
    // 影片寬貼滿畫布寬，高＝(9/16)/(16/9)＝0.3164 個畫布高，上下置中
    const boxH = (9 / 16) / (16 / 9);
    expect(p.path[1], closeTo(0.5, 1e-9));
    expect(p.path[2], closeTo(0.5, 1e-9));
    expect(p.path[3], closeTo(0.1, 1e-9), reason: '寬對畫布寬：影片寬＝畫布寬');
    expect(p.path[4], closeTo(0.2 * boxH, 1e-9));
    expect(p.path[7], closeTo(0.5 - boxH / 2 + 0.25 * boxH, 1e-9));
  });

  test('鏡像：左邊的臉跑到右邊', () {
    final p = planFaceMosaics(
      [
        _track([(0, 0.2, 0.5, 0.1, 0.1), (1, 0.2, 0.5, 0.1, 0.1)]),
      ],
      _video(mirror: true),
      1,
      1,
    ).single;
    expect(p.path[1], closeTo(0.8, 1e-9));
  });

  test('片段播不到的那一段丟掉；整個人都不在片段裡就不建', () {
    final plans = planFaceMosaics(
      [
        _track([
          (0, 0.5, 0.5, 0.1, 0.1),
          (3, 0.5, 0.5, 0.1, 0.1),
          (5, 0.5, 0.5, 0.1, 0.1),
        ]),
        _track([(8, 0.5, 0.5, 0.1, 0.1), (9, 0.5, 0.5, 0.1, 0.1)]),
      ],
      _video(trimStart: 2, trimEnd: 6),
      1,
      1,
    );
    expect(plans.length, 1, reason: '第二個人整段在修剪掉的地方');
    expect(plans.single.offset, closeTo(1.0, 1e-9), reason: '素材 3 秒＝時間軸 1 秒');
    expect(plans.single.length, closeTo(2.0, 1e-9));
  });

  test('轉 90 度：中心繞片段中心轉、寬高對調', () {
    final p = planFaceMosaics(
      [
        _track([(0, 0.75, 0.5, 0.1, 0.2), (1, 0.75, 0.5, 0.1, 0.2)]),
      ],
      _video(rotation: 90),
      1,
      1,
    ).single;
    // 右邊（+0.25, 0）順時針轉 90 度 → 下面（0, +0.25）
    expect(p.path[1], closeTo(0.5, 1e-9));
    expect(p.path[2], closeTo(0.75, 1e-9));
    expect(p.path[3], closeTo(0.2, 1e-9));
    expect(p.path[4], closeTo(0.1, 1e-9));
  });
}
