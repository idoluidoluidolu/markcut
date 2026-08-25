import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';

// 切割/覆蓋切割產生的後半段必須完整保留變形與樣式：
// 以前 splitAt 手抄欄位，mirror/裁切/透明度/旋轉全漏了，
// 切一刀後半段默默變回原樣；複製馬賽克來源時筆畫也沒抄，
// 切割筆刷馬賽克後半段直接蒸發
void main() {
  TimelineModel makeTl() {
    final tl = TimelineModel();
    tl.sources.add(
      MediaSource(
        path: 'v.mp4',
        name: 'v',
        kind: ClipKind.video,
        duration: 10,
        w: 1920,
        h: 1080,
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: 1,
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 10,
        offset: 0,
        track: 0,
        volume: 0.5,
        speed: 2.0,
        mirror: true,
        cropL: 0.1,
        cropT: 0.2,
        cropW: 0.7,
        cropH: 0.6,
        opacity: 0.8,
        rotation: 45,
        px: 0.3,
        py: 0.7,
        scale: 1.4,
      ),
    );
    return tl;
  }

  void expectPreserved(TimelineClip a, TimelineClip b) {
    expect(b.mirror, a.mirror, reason: 'mirror');
    expect(b.cropL, a.cropL, reason: 'cropL');
    expect(b.cropT, a.cropT, reason: 'cropT');
    expect(b.cropW, a.cropW, reason: 'cropW');
    expect(b.cropH, a.cropH, reason: 'cropH');
    expect(b.opacity, a.opacity, reason: 'opacity');
    expect(b.rotation, a.rotation, reason: 'rotation');
    expect(b.volume, a.volume, reason: 'volume');
    expect(b.speed, a.speed, reason: 'speed');
    expect(b.px, a.px, reason: 'px');
    expect(b.py, a.py, reason: 'py');
    expect(b.scale, a.scale, reason: 'scale');
  }

  test('splitAt 後半段保留全部變形欄位', () {
    final tl = makeTl();
    final c = tl.clips.first;
    final second = tl.splitAt(c, 2.0);
    expect(second, isNotNull);
    expectPreserved(c, second!);
  });

  test('carveRange 中段切割的尾段保留全部變形欄位', () {
    final tl = makeTl();
    final c = tl.clips.first;
    final before = c.tailClone(
      id: -1,
      sourceIndex: c.sourceIndex,
      trimStart: c.trimStart,
      trimEnd: c.trimEnd,
      offset: c.offset,
    );
    tl.carveRange(1.0, 2.0, 0);
    // 中段挖掉後應該剩頭尾兩段，尾段欄位齊全
    expect(tl.clips.length, 2);
    final tail = tl.clips.last;
    expectPreserved(before, tail);
  });

  test('切割筆刷馬賽克：後半段來源保留筆畫與貼圖旗標', () {
    final tl = makeTl();
    tl.sources.add(
      MediaSource(
        path: '',
        name: '馬賽克',
        kind: ClipKind.mosaic,
        duration: 0,
        mosaicStyle: MosaicStyle(),
        mosaicStroke: [0.1, 0.1, 0.5, 0.5],
        mosaicBrush: 0.2,
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: 2,
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 1,
      ),
    );
    final second = tl.splitAt(tl.clips.last, 2.0);
    expect(second, isNotNull);
    final dup = tl.sources[second!.sourceIndex];
    expect(dup.mosaicStroke, [0.1, 0.1, 0.5, 0.5]);
    expect(dup.mosaicBrush, 0.2);
    // 深拷貝：改後半段筆畫不影響前半段
    dup.mosaicStroke!.add(0.9);
    expect(tl.sources[1].mosaicStroke!.length, 4);
  });

  test('fromJson 夾速度：speed=0 的壞草稿不會流進 payload', () {
    final c = TimelineClip.fromJson({
      'id': 1,
      'sourceIndex': 0,
      'trimStart': 0.0,
      'trimEnd': 5.0,
      'offset': 0.0,
      'track': 0,
      'speed': 0.0,
    });
    expect(c.speed, 0.1);
  });
}
