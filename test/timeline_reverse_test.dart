import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';

TimelineModel _model({bool reverse = false}) {
  final tl = TimelineModel();
  tl.sources.add(
    MediaSource(
      path: 'a.mp4',
      name: 'a',
      kind: ClipKind.video,
      w: 1920,
      h: 1080,
      duration: 10,
    ),
  );
  tl.clips.add(
    TimelineClip(
      id: tl.nextId(),
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 10,
      offset: 0,
      track: 0,
      reverse: reverse,
    ),
  );
  return tl;
}

void main() {
  group('切割', () {
    test('正播：兩半接得起來、長度加總不變', () {
      final tl = _model();
      final c = tl.clips.first;
      final second = tl.splitAt(c, 3)!;
      expect(c.offset, 0);
      expect(c.length, closeTo(3, 1e-9));
      expect(second.offset, 3);
      expect(second.length, closeTo(7, 1e-9));
      expect(tl.duration, closeTo(10, 1e-9));
    });

    test('倒轉：兩半不重疊，長度不會對調', () {
      final tl = _model(reverse: true);
      final c = tl.clips.first;
      final second = tl.splitAt(c, 3)!;
      // 前半在時間軸上是 0~3，後半 3~10
      expect(c.length, closeTo(3, 1e-9), reason: '前半長度應該等於切點');
      expect(second.length, closeTo(7, 1e-9));
      // 素材區間要互補、不重疊：倒著播先播尾巴
      expect(c.trimStart, closeTo(7, 1e-9));
      expect(c.trimEnd, closeTo(10, 1e-9));
      expect(second.trimStart, closeTo(0, 1e-9));
      expect(second.trimEnd, closeTo(7, 1e-9));
      expect(tl.duration, closeTo(10, 1e-9), reason: '總長不該變');
    });
  });

  group('整理（closeGaps）', () {
    test('只收空隙，不推開刻意重疊的片段', () {
      final tl = _model();
      // 第二段刻意跟第一段重疊
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 4,
          offset: 6, // 第一段是 0~10，這裡重疊
          track: 0,
        ),
      );
      final removed = tl.closeGaps(track: 0);
      expect(removed, 0, reason: '重疊不是空隙，不該回報收掉秒數');
      expect(tl.clips[1].offset, 6, reason: '重疊的片段不該被推開');
    });

    test('真的有空隙才收', () {
      final tl = _model();
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 4,
          offset: 15,
          track: 0,
        ),
      );
      final removed = tl.closeGaps(track: 0);
      expect(removed, closeTo(5, 1e-9));
      expect(tl.clips[1].offset, closeTo(10, 1e-9));
    });
  });

  group('軌號重編回傳對照表', () {
    test('removeTrack：下面的軌往上遞補，對照表對得上', () {
      final tl = TimelineModel();
      tl.sources.add(
        MediaSource(
          path: 'a.mp4',
          name: 'a',
          kind: ClipKind.video,
          w: 16,
          h: 9,
          duration: 5,
        ),
      );
      for (var t = 0; t < 3; t++) {
        tl.clips.add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 5,
            offset: 0,
            track: t,
          ),
        );
      }
      final map = tl.removeTrack(0);
      expect(map[1], 0);
      expect(map[2], 1);
    });
  });
}
