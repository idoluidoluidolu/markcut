// 暴力測試第二輪：專打「播放換手」與「圖層順序」這兩個最容易出事、
// 而且出事時使用者一定看得到（播錯內容／預覽跟成品不一樣）的地方。
//
// 執行：flutter test test/playback_stress_test.dart
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';

/// 播放引擎的「無縫換手」判定條件
/// （跟 video_editor_screen._syncMedia 裡的條件同一套）。
///
/// prev 正在播、clip 剛進場時，如果這個條件成立，引擎會把 prev 的播放器
/// 直接交給 clip 繼續用、而且不重新對位。所以條件一旦誤判，
/// 使用者就會看到「切點之後播的是完全不相干的內容」。
bool handoverAllowed(TimelineClip prev, TimelineClip clip) {
  if (identical(prev, clip)) return false;
  if (prev.sourceIndex != clip.sourceIndex) return false;
  if (prev.track != clip.track) return false;
  if ((prev.end - clip.offset).abs() > 0.05) return false;
  if ((prev.trimEnd - clip.trimStart).abs() > 0.05) return false;
  if ((prev.speed - clip.speed).abs() > 0.001) return false;
  return true;
}

void main() {
  group('播放換手判定', () {
    // 換手安全的定義：把 prev 正在播的播放器直接交給 clip、而且不重新對位，
    // 播放器停的位置必須剛好就是 clip 要的位置。差太多＝使用者看到播錯內容。
    test('通過換手判定的組合，播放器位置一定是對的', () {
      for (var seed = 0; seed < 300; seed++) {
        final r = math.Random(seed);
        final tl = TimelineModel();
        tl.sources.add(
          MediaSource(
            path: '/a.mp4',
            name: 'a',
            kind: ClipKind.video,
            duration: 300,
          ),
        );
        tl.sources.add(
          MediaSource(
            path: '/b.mp4',
            name: 'b',
            kind: ClipKind.video,
            duration: 300,
          ),
        );

        for (var i = 0; i < 6; i++) {
          tl.clips.add(
            TimelineClip(
              id: tl.nextId(),
              sourceIndex: r.nextInt(2),
              trimStart: r.nextDouble() * 50,
              trimEnd: 60 + r.nextDouble() * 100,
              offset: r.nextDouble() * 200,
              track: r.nextInt(3),
              speed: [0.5, 1.0, 2.0][r.nextInt(3)],
            ),
          );
        }

        // 隨機切割＋隨機亂動（移位／修剪／變速）
        for (var i = 0; i < 40; i++) {
          if (tl.clips.isEmpty) break;
          final c = tl.clips[r.nextInt(tl.clips.length)];
          final t = c.offset + r.nextDouble() * c.length;
          final second = tl.splitAt(c, t);
          if (r.nextInt(4) == 0 && second != null) {
            switch (r.nextInt(3)) {
              case 0:
                second.offset += 0.5 + r.nextDouble();
              case 1:
                second.trimStart += 0.5 + r.nextDouble();
              case 2:
                second.speed = second.speed * 2;
            }
          }
        }

        for (final prev in tl.clips) {
          for (final clip in tl.clips) {
            if (identical(prev, clip)) continue;
            if (!handoverAllowed(prev, clip)) continue;
            // prev 播到底時，播放器停在 prev.trimEnd；
            // clip 從它的起點開始要的是 clip.trimStart。
            // 兩者必須夠接近，直接接手才不會播錯段落
            final playerAt = prev.trimEnd;
            final wants = clip.sourceTimeAt(clip.offset);
            expect(
              (playerAt - wants).abs() <= 0.06,
              isTrue,
              reason: 'seed=$seed 片段 ${prev.id}→${clip.id} 通過換手判定，'
                  '但播放器會停在 $playerAt、實際需要 $wants'
                  '（畫面會播錯內容）',
            );
            // 時間軸上也必須是接著的，中間不能有洞
            expect(
              (prev.end - clip.offset).abs() <= 0.06,
              isTrue,
              reason: 'seed=$seed ${prev.id}→${clip.id} 時間軸上不連續',
            );
          }
        }
      }
    });

    test('切割兄弟的換手方向是唯一的（不會反向觸發）', () {
      final r = math.Random(42);
      for (var i = 0; i < 5000; i++) {
        final tl = TimelineModel();
        tl.sources.add(
          MediaSource(
            path: '/a.mp4',
            name: 'a',
            kind: ClipKind.video,
            duration: 300,
          ),
        );
        final c = TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: r.nextDouble() * 50,
          trimEnd: 100 + r.nextDouble() * 100,
          offset: r.nextDouble() * 50,
          track: 0,
          speed: [0.5, 1.0, 2.0, 4.0][r.nextInt(4)],
        );
        tl.clips.add(c);
        final t = c.offset + 0.3 + r.nextDouble() * (c.length - 0.6);
        final second = tl.splitAt(c, t);
        if (second == null) continue;
        // 前半 → 後半：允許（播放方向）
        expect(handoverAllowed(c, second), isTrue,
            reason: '正向換手應該成立，不然切點會卡頓');
        // 後半 → 前半：不允許（倒著播不該換手，會拿到錯位置的播放器）
        expect(handoverAllowed(second, c), isFalse,
            reason: '反向換手成立了——這正是「暫停→切割→播放」播錯內容的原因');
      }
    });

    test('播放頭掃過整條時間軸，每一刻的作用片段都算得出來', () {
      for (var seed = 0; seed < 100; seed++) {
        final r = math.Random(seed + 900);
        final tl = TimelineModel();
        for (var i = 0; i < 4; i++) {
          tl.sources.add(
            MediaSource(
              path: '/x.mp4',
              name: 'x',
              kind: ClipKind.values[r.nextInt(ClipKind.values.length)],
              duration: 120,
              wmStyle: WatermarkSettings(),
              textStyle: TextMark(text: 'a'),
            ),
          );
        }
        for (var i = 0; i < 12; i++) {
          tl.clips.add(
            TimelineClip(
              id: tl.nextId(),
              sourceIndex: r.nextInt(4),
              trimStart: 0,
              trimEnd: 1 + r.nextDouble() * 30,
              offset: r.nextDouble() * 60,
              track: r.nextInt(4),
              speed: [0.25, 1.0, 4.0][r.nextInt(3)],
            ),
          );
        }
        final dur = tl.duration;
        for (var k = 0; k <= 400; k++) {
          final t = dur * k / 400;
          // 這些是每一格畫面都會呼叫的，不能丟例外
          final vids = tl.videosAt(t);
          final overlays = tl.overlaysAt(t);
          final top = tl.videoAt(t);
          // 預覽（videosAt 由下往上畫，最後一個在最上面）
          // 跟「畫面以哪個影片為準」（videoAt）必須是同一個，
          // 不然預覽看到的跟匯出的會是不同片段
          if (vids.isNotEmpty) {
            expect(
              identical(vids.last, top),
              isTrue,
              reason: 'seed=$seed t=$t 預覽最上層跟 videoAt 不一致'
                  '（預覽跟成品會不一樣）',
            );
          } else {
            expect(top, isNull);
          }
          for (final c in [...vids, ...overlays]) {
            // 畫面查詢用的是含結尾的判定（播到最後留最後一幀，
            // 不要黑畫面）——這裡跟著用同一套
            expect(
              c.coversForDisplay(t),
              isTrue,
              reason: '回傳了沒有涵蓋這一刻的片段',
            );
          }
        }
      }
    });

    test('播到總長那一刻仍有畫面（不黑）', () {
      final tl = TimelineModel();
      tl.sources.add(MediaSource(
        path: '/a.mp4',
        name: 'a',
        kind: ClipKind.video,
        duration: 10,
      ));
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 0,
      ));
      final end = tl.duration;
      // 舊的嚴格判定在結尾是開區間＝沒人負責畫面（黑畫面的來源）
      expect(tl.clips.first.covers(end), isFalse);
      // 畫面判定含結尾：最後一幀留著
      expect(tl.videoAt(end), isNotNull, reason: '播完該留最後一幀');
      expect(tl.videosAt(end), isNotEmpty);
    });
  });

  group('圖層順序穩定性', () {
    test('反覆增刪不會讓同一時刻的圖層順序跳動', () {
      final r = math.Random(77);
      final tl = TimelineModel();
      tl.sources.add(
        MediaSource(
          path: '',
          name: 'wm',
          kind: ClipKind.wm,
          duration: 3600,
          wmStyle: WatermarkSettings(),
        ),
      );
      tl.sources.add(
        MediaSource(path: '/v.mp4', name: 'v', kind: ClipKind.video,
            duration: 300),
      );
      for (var i = 0; i < 8; i++) {
        tl.clips.add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: r.nextInt(2),
            trimStart: 0,
            trimEnd: 30,
            offset: 0,
            track: i % 3,
          ),
        );
      }
      // 同一份資料連問 100 次，順序必須完全一樣（不能受 sort 不穩定影響）
      final first = tl.overlaysAt(5).map((c) => c.id).toList();
      for (var i = 0; i < 100; i++) {
        expect(tl.overlaysAt(5).map((c) => c.id).toList(), first,
            reason: '同樣的時間軸問兩次，圖層順序不一樣');
      }
      // 加一個再刪掉，順序要回到原狀
      final tmp = TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 30,
        offset: 0,
        track: 1,
      );
      tl.clips.add(tmp);
      tl.clips.remove(tmp);
      expect(tl.overlaysAt(5).map((c) => c.id).toList(), first,
          reason: '加了又刪之後圖層順序變了');
    });
  });

  group('時間換算一致性', () {
    test('時間軸秒 ↔ 素材秒 來回換算誤差可忽略（變速也一樣）', () {
      final r = math.Random(21);
      for (var i = 0; i < 100000; i++) {
        final speed = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 16.0][r.nextInt(7)];
        final c = TimelineClip(
          id: 1,
          sourceIndex: 0,
          trimStart: r.nextDouble() * 100,
          trimEnd: 0,
          offset: r.nextDouble() * 100,
          track: 0,
          speed: speed,
        );
        c.trimEnd = c.trimStart + 1 + r.nextDouble() * 100;
        final t = c.offset + r.nextDouble() * c.length;
        final srcT = c.sourceTimeAt(t);
        // 素材秒必須落在修剪範圍內（超出去就是播到不該播的地方）
        expect(
          srcT >= c.trimStart - 0.001 && srcT <= c.trimEnd + 0.001,
          isTrue,
          reason: 'speed=$speed 換算出界：$srcT 不在 '
              '${c.trimStart}~${c.trimEnd}',
        );
        // 反推回時間軸秒要對得回來
        final back = c.offset + (srcT - c.trimStart) / speed.clamp(0.1, 16.0);
        expect((back - t).abs() < 0.001, isTrue,
            reason: 'speed=$speed 來回換算差 ${(back - t).abs()}');
      }
    });
  });
}
