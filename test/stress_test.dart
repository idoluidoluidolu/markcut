// 暴力測試：對模型層做大量隨機操作，檢查「不管怎麼亂搞都必須成立」的條件。
//
// 這裡只測純邏輯（時間軸、調色、浮水印設定、序列化），不碰 UI 與 FFmpeg，
// 所以跑得很快，可以一次跑幾萬回合。失敗訊息會印出亂數種子，能重現。
//
// 執行：flutter test test/stress_test.dart
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/color_grade.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';

/// 每個回合結束都必須成立的條件；違反就是 bug
void checkInvariants(TimelineModel tl, String where) {
  for (final c in tl.clips) {
    expect(
      c.sourceIndex >= 0 && c.sourceIndex < tl.sources.length,
      isTrue,
      reason: '$where: 片段指向不存在的素材 ${c.sourceIndex}',
    );
    expect(c.trimStart.isFinite, isTrue, reason: '$where: trimStart 非數值');
    expect(c.trimEnd.isFinite, isTrue, reason: '$where: trimEnd 非數值');
    expect(c.offset.isFinite, isTrue, reason: '$where: offset 非數值');
    expect(c.offset >= 0, isTrue, reason: '$where: offset 為負 ${c.offset}');
    expect(
      c.trimEnd >= c.trimStart,
      isTrue,
      reason: '$where: trim 反了 ${c.trimStart}>${c.trimEnd}',
    );
    expect(c.length.isFinite, isTrue, reason: '$where: 長度非數值');
    expect(c.end.isFinite, isTrue, reason: '$where: 結尾非數值');
    expect(c.track >= 0, isTrue, reason: '$where: 軌號為負 ${c.track}');
    expect(c.speed > 0, isTrue, reason: '$where: 速度非正 ${c.speed}');
    // 播放引擎會用這個換算，不能爆
    final mid = c.offset + c.length / 2;
    expect(c.sourceTimeAt(mid).isFinite, isTrue, reason: '$where: 素材時間非數值');
    final f = c.fadeFactorAt(mid);
    expect(f >= 0 && f <= 1, isTrue, reason: '$where: 淡化係數超出 0~1 ($f)');
  }
  expect(tl.duration.isFinite, isTrue, reason: '$where: 總長非數值');
  expect(tl.duration >= 0, isTrue, reason: '$where: 總長為負');
  // id 不能重複，不然選取／播放器對應會錯亂
  final ids = tl.clips.map((c) => c.id).toList();
  expect(ids.toSet().length, ids.length, reason: '$where: 片段 id 重複');
}

/// 編輯器的復原快照（跟 video_editor_screen._snapshot 同一套）
String snapshot(TimelineModel tl) => jsonEncode({
  'clips': [for (final c in tl.clips) c.toJson()],
  'sources': [for (final s in tl.sources) s.toJson()],
});

void restore(TimelineModel tl, String snap) {
  final j = jsonDecode(snap) as Map<String, dynamic>;
  tl.sources
    ..clear()
    ..addAll([
      for (final s in (j['sources'] as List))
        MediaSource.fromJson(Map<String, dynamic>.from(s as Map)),
    ]);
  tl.clips
    ..clear()
    ..addAll([
      for (final c in (j['clips'] as List))
        TimelineClip.fromJson(Map<String, dynamic>.from(c as Map)),
    ]);
  var maxId = -1;
  for (final c in tl.clips) {
    if (c.id > maxId) maxId = c.id;
  }
  tl.ensureIdAbove(maxId);
}

MediaSource randomSource(math.Random r) {
  final kind = ClipKind.values[r.nextInt(ClipKind.values.length)];
  return MediaSource(
    path: kind == ClipKind.text || kind == ClipKind.wm ? '' : '/tmp/a.mp4',
    name: '素材${r.nextInt(999)}',
    kind: kind,
    duration: kind == ClipKind.image || kind == ClipKind.text
        ? 3600
        : 1 + r.nextDouble() * 600,
    w: 1920,
    h: 1080,
    textStyle: kind == ClipKind.text ? TextMark(text: '字') : null,
    wmStyle: kind == ClipKind.wm ? WatermarkSettings() : null,
  );
}

void main() {
  group('時間軸暴力測試', () {
    test('20 萬次隨機操作後不變條件都成立', () {
      for (var seed = 0; seed < 200; seed++) {
        final r = math.Random(seed);
        final tl = TimelineModel();
        // 起手先給幾個素材
        for (var i = 0; i < 3; i++) {
          tl.sources.add(randomSource(r));
        }
        for (var step = 0; step < 1000; step++) {
          final op = r.nextInt(9);
          switch (op) {
            case 0: // 新增素材與片段
              tl.sources.add(randomSource(r));
              final si = tl.sources.length - 1;
              final dur = tl.sources[si].duration;
              tl.clips.add(
                TimelineClip(
                  id: tl.nextId(),
                  sourceIndex: si,
                  trimStart: 0,
                  trimEnd: math.min(dur, 1 + r.nextDouble() * 20),
                  offset: r.nextDouble() * 60,
                  track: r.nextInt(5),
                  speed: [0.25, 0.5, 1.0, 2.0, 4.0][r.nextInt(5)],
                  fadeIn: r.nextDouble() * 2,
                  fadeOut: r.nextDouble() * 2,
                ),
              );
            case 1: // 隨機切割
              if (tl.clips.isEmpty) break;
              final c = tl.clips[r.nextInt(tl.clips.length)];
              final t = c.offset + r.nextDouble() * c.length;
              final before = c.length;
              final beforeSrc = c.sourceIndex;
              final second = tl.splitAt(c, t);
              if (second != null) {
                // 切完兩段必須接得起來、總長不變
                expect(
                  (c.end - second.offset).abs() < 0.01,
                  isTrue,
                  reason: 'seed=$seed 切割後有縫隙',
                );
                expect(
                  (c.trimEnd - second.trimStart).abs() < 0.01,
                  isTrue,
                  reason: 'seed=$seed 切割後素材時間不連續',
                );
                expect(
                  (c.length + second.length - before).abs() < 0.05,
                  isTrue,
                  reason: 'seed=$seed 切割後總長變了',
                );
                expect(c.fadeOut, 0, reason: 'seed=$seed 前半的淡出沒清掉');
                // 浮水印／文字：兩半不可共用來源（改一半會動到另一半）
                final k = tl.sources[beforeSrc].kind;
                if (k == ClipKind.wm || k == ClipKind.text) {
                  expect(
                    second.sourceIndex != beforeSrc,
                    isTrue,
                    reason: 'seed=$seed 切割後兩半共用樣式來源',
                  );
                }
              }
            case 2: // 隨機移動（含吸附）
              if (tl.clips.isEmpty) break;
              final c = tl.clips[r.nextInt(tl.clips.length)];
              final want = (r.nextDouble() - 0.2) * 80;
              final px = [1.0, 8.0, 60.0, 200.0][r.nextInt(4)];
              final o = tl.snapOffset(c, want, r.nextDouble() * 60, px);
              expect(o.isFinite && o >= 0, isTrue, reason: 'seed=$seed 吸附算壞了');
              c.offset = o;
            case 3: // 隨機修剪
              if (tl.clips.isEmpty) break;
              final c = tl.clips[r.nextInt(tl.clips.length)];
              final src = tl.sourceOf(c);
              if (r.nextBool()) {
                c.trimStart = (c.trimStart + (r.nextDouble() - 0.5) * 4).clamp(
                  0.0,
                  math.max(0.0, c.trimEnd - 0.3),
                );
              } else {
                c.trimEnd = (c.trimEnd + (r.nextDouble() - 0.5) * 4).clamp(
                  c.trimStart + 0.3,
                  math.max(c.trimStart + 0.3, src.duration),
                );
              }
            case 4: // 刪除
              if (tl.clips.isEmpty) break;
              tl.clips.removeAt(r.nextInt(tl.clips.length));
            case 5: // 換軌 + 收斂軌號
              if (tl.clips.isEmpty) break;
              tl.clips[r.nextInt(tl.clips.length)].track = r.nextInt(6);
              if (r.nextBool()) tl.compactTracks();
            case 6: // 變速
              if (tl.clips.isEmpty) break;
              tl.clips[r.nextInt(tl.clips.length)].speed =
                  [0.1, 0.25, 1.0, 4.0, 16.0][r.nextInt(5)];
            case 7: // 快照 → 亂改 → 還原，必須完全回到原狀
              final snap = snapshot(tl);
              if (tl.clips.isNotEmpty) {
                tl.clips.removeAt(r.nextInt(tl.clips.length));
              }
              tl.sources.add(randomSource(r));
              restore(tl, snap);
              expect(
                snapshot(tl),
                snap,
                reason: 'seed=$seed 復原後狀態跟快照不一致',
              );
            case 8: // 整段位移
              tl.shiftAfter(r.nextInt(5), r.nextDouble() * 30,
                  (r.nextDouble() - 0.5) * 20);
          }
          checkInvariants(tl, 'seed=$seed step=$step op=$op');
        }
      }
    });

    test('片段 JSON 來回不失真（含調色、淡化、變速）', () {
      final r = math.Random(7);
      for (var i = 0; i < 20000; i++) {
        final c = TimelineClip(
          id: r.nextInt(99999),
          sourceIndex: r.nextInt(50),
          trimStart: r.nextDouble() * 100,
          trimEnd: 100 + r.nextDouble() * 100,
          offset: r.nextDouble() * 500,
          track: r.nextInt(10),
          volume: r.nextDouble(),
          px: r.nextDouble(),
          py: r.nextDouble(),
          scale: 0.05 + r.nextDouble() * 12,
          fadeIn: r.nextDouble() * 3,
          fadeOut: r.nextDouble() * 3,
          speed: 0.1 + r.nextDouble() * 15.9,
          color: ColorGrade()
            ..balR = r.nextDouble() * 2 - 1
            ..balG = r.nextDouble() * 2 - 1
            ..balB = r.nextDouble() * 2 - 1
            ..saturation = r.nextDouble() * 2
            ..brightness = r.nextDouble() * 2 - 1
            ..contrast = r.nextDouble() * 3
            ..exposure = r.nextDouble() * 2 - 1,
        );
        final a = jsonEncode(c.toJson());
        final b = jsonEncode(TimelineClip.fromJson(jsonDecode(a)).toJson());
        expect(b, a, reason: '第 $i 個片段來回後不一樣');
      }
    });

    test('壞掉的草稿 JSON 不會讓 App 爆掉', () {
      final hostile = <Map<String, dynamic>>[
        {},
        {'kind': 999999},
        {'kind': -5},
        {'trimStart': 100, 'trimEnd': 0},
        {'speed': 0},
        {'speed': -3},
        {'speed': 1e18},
        {'offset': -50},
        {'sourceIndex': 999},
        {'duration': -1},
        {'saturation': 99, 'contrast': -99, 'exposure': 1e9},
      ];
      for (final j in hostile) {
        final s = MediaSource.fromJson(j);
        expect(s.kind, isNotNull);
        expect(s.duration.isFinite, isTrue);
        final c = TimelineClip.fromJson(j);
        expect(c.length.isFinite, isTrue, reason: '壞資料讓長度變成非數值：$j');
        expect(c.end.isFinite, isTrue, reason: '壞資料讓結尾變成非數值：$j');
        expect(c.sourceTimeAt(1).isFinite, isTrue, reason: '壞資料讓換算爆掉：$j');
        expect(c.fadeFactorAt(1).isFinite, isTrue);
      }
    });
  });

  group('調色暴力測試', () {
    test('任何組合產生的 FFmpeg 濾鏡都是合法的', () {
      final r = math.Random(3);
      for (var i = 0; i < 50000; i++) {
        final g = ColorGrade()
          ..balR = r.nextDouble() * 2 - 1
          ..balG = r.nextDouble() * 2 - 1
          ..balB = r.nextDouble() * 2 - 1
          ..saturation = r.nextDouble() * 2 // 面板上限 2.0
          ..brightness = r.nextDouble() * 2 - 1
          ..contrast = r.nextDouble() * 3
          ..exposure = r.nextDouble() * 2 - 1;
        final f = g.ffmpeg;
        expect(f.contains('NaN'), isFalse, reason: '濾鏡含 NaN：$f');
        expect(f.contains('Infinity'), isFalse, reason: '濾鏡含 Infinity：$f');
        // LGPL 版沒有這些 GPL 濾鏡，用了會整個匯出失敗
        expect(f.contains('eq='), isFalse, reason: '用到 GPL 濾鏡 eq：$f');
        expect(f.contains('hue='), isFalse, reason: '用到 GPL 濾鏡 hue：$f');
        expect(f.contains('curves='), isFalse, reason: '用到 GPL 濾鏡 curves：$f');
        if (f.isNotEmpty) {
          expect(f.startsWith(','), isTrue, reason: '濾鏡沒有前置逗號：$f');
        }
        // colorchannelmixer 每個係數硬上限是 2.0，超過濾鏡初始化就失敗
        for (final m in RegExp(r'[rgb][rgb]=(-?[\d.]+)').allMatches(f)) {
          final v = double.parse(m.group(1)!);
          expect(
            v.abs() <= 2.0,
            isTrue,
            reason: 'colorchannelmixer 係數 $v 超過 FFmpeg 上限：$f',
          );
        }
        // 預覽用的矩陣要是 20 個有限數字，不然畫面會整片黑
        final mtx = g.matrix;
        expect(mtx.length, 20);
        for (final v in mtx) {
          expect(v.isFinite, isTrue, reason: '預覽矩陣有非數值：$mtx');
        }
      }
    });

    test('調色 JSON 來回不失真', () {
      final r = math.Random(11);
      for (var i = 0; i < 20000; i++) {
        final g = ColorGrade()
          ..balR = r.nextDouble() * 2 - 1
          ..balG = r.nextDouble() * 2 - 1
          ..balB = r.nextDouble() * 2 - 1
          ..saturation = r.nextDouble() * 3
          ..brightness = r.nextDouble() * 2 - 1
          ..contrast = r.nextDouble() * 3
          ..exposure = r.nextDouble() * 2 - 1;
        final a = jsonEncode(g.toJson());
        final b = jsonEncode(ColorGrade.fromJson(jsonDecode(a)).toJson());
        expect(b, a);
      }
    });
  });

  group('浮水印設定暴力測試', () {
    test('動畫參數再怎麼亂都不會產生 Infinity（會炸匯出）', () {
      final hostile = <double>[0, -1, -0.0001, 1e-12, 1e12, 0.2, 3.0];
      for (final sp in hostile) {
        for (final rg in hostile) {
          final s = WatermarkSettings.fromJson({
            'animation': 1,
            'animSpeed': sp,
            'animRange': rg,
          });
          expect(s.blinkCycle.isFinite, isTrue, reason: 'animSpeed=$sp 週期爆掉');
          expect(s.blinkCycle > 0, isTrue, reason: 'animSpeed=$sp 週期非正');
          expect(s.blinkOn.isFinite, isTrue);
          expect(s.marqueeCycle.isFinite, isTrue);
          expect(s.marqueeCycle > 0, isTrue);
          for (final t in [0.0, 1.0, 37.5, 1e6]) {
            final a = s.animAt(t);
            expect(a.dx.isFinite && a.dy.isFinite && a.alpha.isFinite, isTrue,
                reason: 'animAt($t) 在 animSpeed=$sp 時爆掉');
          }
        }
      }
    });

    test('浮水印設定 JSON 來回不失真（含 Logo 位元組）', () {
      final r = math.Random(5);
      for (var i = 0; i < 5000; i++) {
        final s = WatermarkSettings();
        s.text.text = ['', '@我的頻道', 'a' * 200, '換\n行', '引"號', '逗,號'][
            r.nextInt(6)];
        s.text.x = r.nextDouble();
        s.text.y = r.nextDouble();
        s.text.sizeFrac = 0.015 + r.nextDouble() * 2;
        s.text.rotation = r.nextDouble() * 360 - 180;
        s.text.tiled = r.nextBool();
        s.text.enabled = r.nextBool();
        s.logo.enabled = r.nextBool();
        s.logo.sizeFrac = 0.03 + r.nextDouble() * 2;
        s.animation = WmAnimation.values[r.nextInt(WmAnimation.values.length)];
        s.animSpeed = 0.2 + r.nextDouble() * 2.8;
        s.animRange = 0.2 + r.nextDouble() * 2.8;
        final a = jsonEncode(s.toJson());
        final b = jsonEncode(WatermarkSettings.fromJson(jsonDecode(a)).toJson());
        expect(b, a, reason: '第 $i 組浮水印設定來回後不一樣');
        // copy() 必須是深拷貝，改複本不能動到本尊
        final cp = s.copy();
        cp.text.x = 0.123456;
        cp.logo.sizeFrac = 1.987654;
        expect(s.text.x == 0.123456, isFalse, reason: 'copy() 不是深拷貝（文字）');
        expect(s.logo.sizeFrac == 1.987654, isFalse, reason: 'copy() 不是深拷貝（Logo）');
      }
    });
  });

  group('吸附（磁鐵）行為', () {
    test('縮放到極端時吸附範圍仍受控，且永不回傳負值', () {
      final r = math.Random(13);
      final tl = TimelineModel();
      tl.sources.add(
        MediaSource(path: '/a.mp4', name: 'a', kind: ClipKind.video,
            duration: 100),
      );
      for (var i = 0; i < 6; i++) {
        tl.clips.add(TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 5,
          offset: i * 7.0,
          track: 0,
        ));
      }
      final moving = tl.clips.first;
      for (var i = 0; i < 20000; i++) {
        final px = [0.5, 1.0, 6.0, 60.0, 200.0, 1e4][r.nextInt(6)];
        final want = (r.nextDouble() - 0.3) * 200;
        final head = r.nextDouble() * 100;
        final got = tl.snapOffset(moving, want, head, px);
        expect(got.isFinite, isTrue);
        expect(got >= 0, isTrue, reason: '吸附回傳負值 $got');
        // 吸附幅度：手感是 24px，但秒數上限 2 秒——
        // 不設上限的話縮到最小時整條軸都在吸，沒辦法自由擺位
        if (want >= 0) {
          final moved = (got - want).abs();
          expect(
            moved <= math.min(24 / px, 2.0) + 0.0001,
            isTrue,
            reason: 'px=$px want=$want 被吸走 $moved 秒（超過該有的範圍）',
          );
        }
      }
    });
  });
}
