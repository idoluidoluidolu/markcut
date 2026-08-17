// 邊緣暴力測試：專打這一輪的新行為。
//
// 核心武器是「內容守恆」：對 carveRange 來說，被蓋範圍以外的每一個
// 時間點，蓋完之後必須還是同一份素材的同一格（sourceTimeAt 不變）。
// 這條不變量比任何逐案斷言都兇——裁切、切半、位移只要有一個換算錯，
// 隨機轟一萬次一定露餡。
import 'dart:math' as math;

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/crop_math.dart';
import 'package:markcut/services/video_processor.dart';

TimelineModel _base() {
  final tl = TimelineModel();
  tl.sources.add(
    MediaSource(
      path: '/a.mp4',
      name: 'a',
      kind: ClipKind.video,
      duration: 1000,
    ),
  );
  return tl;
}

void main() {
  group('carveRange 內容守恆', () {
    test('隨機片段、隨機蓋範圍：範圍外每一格都不許變', () {
      final r = math.Random(42);
      for (var round = 0; round < 3000; round++) {
        final tl = _base();
        // 1~4 段，隨機速度／倒轉／淡化，刻意允許彼此重疊
        final n = 1 + r.nextInt(4);
        for (var i = 0; i < n; i++) {
          final speed = [0.25, 0.5, 1.0, 2.0, 4.0, 16.0][r.nextInt(6)];
          final srcLen = 1 + r.nextDouble() * 40;
          final trimStart = r.nextDouble() * 100;
          tl.clips.add(
            TimelineClip(
              id: tl.nextId(),
              sourceIndex: 0,
              trimStart: trimStart,
              trimEnd: trimStart + srcLen,
              offset: r.nextDouble() * 30,
              track: 0,
              speed: speed,
              reverse: r.nextBool(),
              fadeIn: r.nextDouble() * 2,
              fadeOut: r.nextDouble() * 2,
            ),
          );
        }
        final a = r.nextDouble() * 40 - 2;
        final b = a + r.nextDouble() * 20;

        // 蓋之前：抽樣記下「這一刻是誰、放的是素材第幾秒」
        final probes = <({double t, int clipId, double srcT})>[];
        for (var i = 0; i < 60; i++) {
          final t = r.nextDouble() * 50;
          if (t >= a - 0.06 && t <= b + 0.06) continue; // 蓋範圍附近不驗
          for (final c in tl.clips) {
            // 頭尾 0.06 秒內的點不驗：碎屑清理（<0.05）允許動到它們
            if (t < c.offset + 0.06 || t > c.end - 0.06) continue;
            probes.add((t: t, clipId: c.id, srcT: c.sourceTimeAt(t)));
          }
        }

        tl.carveRange(a, b, 0);

        // 1) 蓋範圍中間必須清空
        for (final c in tl.clips) {
          final overlap =
              math.min(c.end, b - 0.01) - math.max(c.offset, a + 0.01);
          expect(
            overlap <= 0.011,
            isTrue,
            reason: 'round=$round 蓋完 [$a,$b) 還有片段佔著 '
                '${c.offset}~${c.end}',
          );
        }
        // 2) 範圍外的每一個抽樣點：同一份素材的同一格還在原地
        for (final p in probes) {
          final hit = [
            for (final c in tl.clips)
              if (c.covers(p.t)) c,
          ];
          expect(
            hit,
            isNotEmpty,
            reason: 'round=$round t=${p.t} 原本有畫面，蓋完消失了',
          );
          final same = hit.any((c) => (c.sourceTimeAt(p.t) - p.srcT).abs() < 1e-6);
          expect(
            same,
            isTrue,
            reason: 'round=$round t=${p.t} 素材時間跑掉：'
                '原本 ${p.srcT}，現在 ${hit.map((c) => c.sourceTimeAt(p.t))}',
          );
        }
        // 3) 基本健康：長度為正、數字有限
        for (final c in tl.clips) {
          expect(c.srcLength > 0, isTrue, reason: 'round=$round 空片段殘留');
          expect(c.offset.isFinite && c.end.isFinite, isTrue);
        }
      }
    });

    test('樣式素材（文字）切半後兩半不共用來源', () {
      final tl = TimelineModel();
      tl.sources.add(
        MediaSource(
          path: '',
          name: '哈囉',
          kind: ClipKind.text,
          duration: 3600,
          textStyle: TextMark(text: '哈囉'),
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
        ),
      );
      tl.carveRange(4, 6, 0);
      expect(tl.clips.length, 2);
      final head = tl.clips.firstWhere((c) => c.offset < 1);
      final tail = tl.clips.firstWhere((c) => c.offset > 1);
      expect(
        head.sourceIndex != tail.sourceIndex,
        isTrue,
        reason: '切半後共用來源：改一半的樣式另一半會跟著變',
      );
    });
  });

  group('closeGaps 邊緣', () {
    test('多軌一起整理：每一軌各自保住第一段的位置', () {
      final r = math.Random(9);
      for (var round = 0; round < 500; round++) {
        final tl = _base();
        final firstOffsets = <int, double>{};
        for (var t = 0; t < 3; t++) {
          var off = r.nextDouble() * 5;
          firstOffsets[t] = off;
          for (var i = 0; i < 3; i++) {
            tl.clips.add(
              TimelineClip(
                id: tl.nextId(),
                sourceIndex: 0,
                trimStart: 0,
                trimEnd: 2,
                offset: off,
                track: t,
              ),
            );
            off += 2 + r.nextDouble() * 4; // 留空隙
          }
        }
        tl.closeGaps();
        for (var t = 0; t < 3; t++) {
          final list = tl.onTrack(t);
          expect(list.first.offset, closeTo(firstOffsets[t]!, 1e-9),
              reason: 'round=$round 第 $t 軌的第一段被搬走了');
          for (var i = 1; i < list.length; i++) {
            expect(list[i].offset, closeTo(list[i - 1].end, 1e-9),
                reason: 'round=$round 第 $t 軌還有空隙');
          }
        }
      }
    });

    test('刻意重疊的片段不被推開、不算進收掉的秒數', () {
      final tl = _base();
      for (final off in [0.0, 1.0]) {
        tl.clips.add(
          TimelineClip(
            id: tl.nextId(),
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 5,
            offset: off,
            track: 0,
          ),
        );
      }
      final removed = tl.closeGaps(track: 0);
      expect(removed, lessThan(0.001));
      expect(tl.clips[1].offset, 1.0);
    });
  });

  group('吸附邊緣', () {
    test('整條軸空的：想放哪就放哪，只有片頭附近會吸 0', () {
      final tl = _base();
      final lone = TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 0,
      );
      tl.clips.add(lone);
      // 60px/秒：半徑 16px ≈ 0.27 秒
      expect(tl.snapOffset(lone, 0.2, 60), 0);
      expect(tl.snapOffset(lone, 5.0, 60), 5.0);
    });

    test('候選點是負數（cand - len < 0）永不外洩', () {
      final tl = _base();
      final long = TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 50,
        offset: 0,
        track: 1,
      );
      final other = TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 2,
        offset: 3,
        track: 0,
      );
      tl.clips.addAll([long, other]);
      // 「別段結尾 - 自己長度」是負的：不該吸到負數
      final got = tl.snapOffset(long, 0.1, 60);
      expect(got >= 0, isTrue);
    });
  });

  group('裁切換算邊緣', () {
    test('鏡像來回：翻框→換算→再換算→翻回，仍包住原框', () {
      final r = math.Random(21);
      for (var i = 0; i < 3000; i++) {
        final srcAspect = 0.2 + r.nextDouble() * 4;
        final canvasAspect = 0.2 + r.nextDouble() * 4;
        final w = 0.1 + r.nextDouble() * 0.9;
        final h = 0.1 + r.nextDouble() * 0.9;
        final crop = Rect.fromLTWH(
          r.nextDouble() * (1 - w),
          r.nextDouble() * (1 - h),
          w,
          h,
        );
        // 鏡像片段的實際流程：UI 給的框先翻、換算、存檔；
        // 重開時反換算、再翻回 UI
        final t = cropToTransform(flipRectX(crop), srcAspect, canvasAspect);
        final back = flipRectX(
          transformToCrop(t.scale, t.px, t.py, srcAspect, canvasAspect),
        );
        expect(back.left, lessThanOrEqualTo(crop.left + 1e-6));
        expect(back.right, greaterThanOrEqualTo(crop.right - 1e-6));
        expect(back.top, lessThanOrEqualTo(crop.top + 1e-6));
        expect(back.bottom, greaterThanOrEqualTo(crop.bottom - 1e-6));
        expect(t.scale.isFinite && t.scale > 0, isTrue);
      }
    });
  });

  group('fastExportSources 邊緣', () {
    test('一支都沒換時回傳同一份清單（不白抄）', () {
      final src = MediaSource(
        path: '/a.mp4',
        name: 'a',
        kind: ClipKind.video,
        duration: 10,
      );
      final list = [src];
      final (out, n) = fastExportSources(
        list,
        outW: 1080,
        outH: 1920,
        quality: ExportQuality.standard,
      );
      expect(n, 0);
      expect(identical(out, list), isTrue);
    });
  });
}
