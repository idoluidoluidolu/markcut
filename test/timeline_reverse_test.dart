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

  group('整理：片頭空白（fromZero）', () {
    /// 第一段從 [start] 開始、長 10 秒，後面再接一段中間留空隙的
    TimelineModel withHead(double start) {
      final tl = _model();
      tl.clips.first.offset = start;
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 4,
          offset: start + 15,
          track: 0,
        ),
      );
      return tl;
    }

    test('不給 fromZero：片頭空白留著，只補中間的洞', () {
      final tl = withHead(3);
      final removed = tl.closeGaps(track: 0);
      expect(tl.clips[0].offset, closeTo(3, 1e-9), reason: '第一段不該被搬走');
      expect(tl.clips[1].offset, closeTo(13, 1e-9), reason: '中間的洞要補');
      expect(removed, closeTo(5, 1e-9), reason: '收掉的只有中間那 5 秒');
    });

    test('fromZero：整軌拉回 0，收掉的秒數含片頭那段', () {
      final tl = withHead(3);
      final removed = tl.closeGaps(track: 0, fromZero: true);
      expect(tl.clips[0].offset, 0, reason: '第一段要補到最開始');
      expect(tl.clips[1].offset, closeTo(10, 1e-9), reason: '後面接著第一段');
      // 片頭 3 秒；第一段拉回 0 之後，第二段跟它之間的距離變成 8 秒
      expect(removed, closeTo(11, 1e-9), reason: '片頭 3 秒＋第二段前面 8 秒');
    });

    test('fromZero：本來就貼著 0 的軌道原地不動、不回報收掉秒數', () {
      final tl = withHead(0);
      tl.clips[1].offset = 10;
      final removed = tl.closeGaps(track: 0, fromZero: true);
      expect(tl.clips[0].offset, 0);
      expect(tl.clips[1].offset, closeTo(10, 1e-9));
      expect(removed, lessThan(0.001));
    });

    test('fromZero＋track: null：每一軌各自拉回 0', () {
      final tl = withHead(3);
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 4,
          offset: 7,
          track: 1,
        ),
      );
      tl.closeGaps(fromZero: true);
      expect(tl.onTrack(0).first.offset, 0);
      expect(tl.onTrack(1).first.offset, 0, reason: '第二軌也要拉回 0');
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
