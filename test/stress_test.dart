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
import 'package:markcut/services/comp_player.dart';
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
              final o = tl.snapOffset(c, want, px);
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
          reverse: r.nextBool(),
          mirror: r.nextBool(),
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

    test('多張圖片：加、刪、切換都不會越界，logo 永遠有東西可回傳', () {
      final r = math.Random(21);
      final s = WatermarkSettings();
      expect(s.logos.length, 1, reason: '一開始就要有一張（空的）');
      for (var i = 0; i < 3000; i++) {
        switch (r.nextInt(3)) {
          case 0:
            s.addLogo().b64 = 'img$i';
          case 1:
            s.removeLogo(r.nextInt(s.logos.length + 2) - 1);
          case 2:
            s.activeLogo = r.nextInt(12) - 4;
        }
        expect(s.logos.isNotEmpty, isTrue, reason: '清單被清空了');
        expect(s.activeLogo >= 0 && s.activeLogo < s.logos.length, isTrue,
            reason: '操作中的索引跑出範圍：${s.activeLogo}/${s.logos.length}');
        expect(s.logo, same(s.logos[s.activeLogo]));
      }
    });

    test('多張圖片：JSON 來回不失真，舊版單張草稿也讀得回來', () {
      final s = WatermarkSettings();
      s.logo.b64 = 'first';
      s.logo.enabled = true;
      s.addLogo().b64 = 'second';
      s.addLogo().b64 = 'third';
      s.activeLogo = 1;
      final a = jsonEncode(s.toJson());
      final back = WatermarkSettings.fromJson(jsonDecode(a));
      expect(jsonEncode(back.toJson()), a, reason: '多張圖片來回後不一樣');
      expect(back.logos.length, 3);
      expect(back.activeLogo, 1, reason: '操作中的那張要記住');
      expect(back.logos[2].b64, 'third');

      // 舊草稿／舊範本只有單張的 logo 鍵
      final old = WatermarkSettings.fromJson({
        'text': {'text': 'x'},
        'logo': {'b64': 'legacy', 'enabled': true},
      });
      expect(old.logos.length, 1);
      expect(old.logo.b64, 'legacy');
      expect(old.hasAnyMark, isTrue);

      // 沒有任何圖片時 logo 還是要能取（空的那張）
      final empty = WatermarkSettings();
      expect(empty.logo.b64, isNull);
      expect(empty.logos.length, 1);
      empty.removeLogo(0);
      expect(empty.logos.length, 1, reason: '最後一張只清空、不移除');

      // 只有第二張有圖也算有浮水印（hasAnyMark 不能只看操作中的那張）
      final second = WatermarkSettings();
      second.addLogo().b64 = 'only-here';
      second.activeLogo = 0;
      expect(second.hasAnyMark, isTrue);
    });
  });

  group('圖層上下關係', () {
    // 時間軸上面那一列＝編號大＝畫面上蓋在上面。預覽、匯出、原生
    // 合成播放器三邊都得同一套，不然「預覽長這樣、匯出不一樣」
    TimelineModel twoLayers() {
      final tl = TimelineModel();
      tl.sources.add(MediaSource(
          path: '/a.mp4', name: 'a', kind: ClipKind.video, duration: 100));
      tl.sources.add(MediaSource(
          path: '/b.png', name: 'b', kind: ClipKind.image, duration: 100));
      for (final (src, track) in [(0, 0), (0, 1), (1, 0), (1, 2)]) {
        tl.clips.add(TimelineClip(
          id: tl.nextId(),
          sourceIndex: src,
          trimStart: 0,
          trimEnd: 10,
          offset: 0,
          track: track,
        ));
      }
      return tl;
    }

    test('編號大的疊在上面', () {
      final tl = twoLayers();
      // 由下層到上層＝編號由小到大
      expect(tl.videosAt(1).map((c) => c.track).toList(), [0, 1]);
      expect(tl.overlaysAt(1).map((c) => c.track).toList(), [0, 2]);
      // 單選一個「看得到的那個」＝最上層
      expect(tl.videoAt(1)!.track, 1);
    });
  });

  group('合成播放器的適用範圍', () {
    TimelineModel base() {
      final tl = TimelineModel();
      tl.sources.add(MediaSource(
          path: '/a.mp4', name: 'a', kind: ClipKind.video, duration: 100));
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 0,
      ));
      return tl;
    }

    test('乾淨的時間軸走合成播放器', () {
      expect(CompPlayer.whyNot(base()), isNull);
    });

    test('有馬賽克就退回材質那條路', () {
      // 馬賽克是 Flutter 的 BackdropFilter，取不到系統影片圖層的像素
      final tl = base();
      tl.sources.add(MediaSource(
          path: '', name: '', kind: ClipKind.mosaic, duration: 3600));
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 3,
        offset: 0,
        track: 1,
      ));
      expect(CompPlayer.whyNot(tl), '有馬賽克');
    });

    test('有圖片素材就退回：墊在影片下層的圖片會被播放器圖層蓋黑', () {
      final tl = base();
      tl.sources.add(MediaSource(
          path: '/p.png', name: 'p', kind: ClipKind.image, duration: 3600));
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 3,
        offset: 0,
        track: 0,
      ));
      expect(CompPlayer.whyNot(tl), '有圖片素材');
    });

    test('影片播完後面還有文字：合成只到影片結尾，時鐘會卡住', () {
      final tl = base(); // 影片 0~5 秒
      tl.sources.add(MediaSource(
          path: '',
          name: '哈囉',
          kind: ClipKind.text,
          duration: 3600,
          textStyle: TextMark(text: '哈囉')));
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 9, // 文字拖到 9 秒，比影片長
        offset: 0,
        track: 1,
      ));
      expect(CompPlayer.whyNot(tl), '影片結束後還有其他素材');
    });

    test('撞號的片段 id 載入時要補新號（兩軌同時亮燈的根因）', () {
      final tl = TimelineModel();
      tl.sources.add(MediaSource(
          path: '/a.mp4', name: 'a', kind: ClipKind.video, duration: 100));
      for (final t in [0, 1, 2]) {
        tl.clips.add(TimelineClip(
          id: 7, // 三個全撞同一號
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 5,
          offset: 0,
          track: t,
        ));
      }
      final fixed = tl.fixDuplicateIds();
      expect(fixed, 2, reason: '第一個保留原號，後兩個補新號');
      expect(tl.clips.map((c) => c.id).toSet().length, 3);
      expect(tl.clips.first.id, 7);
      // 補完之後再配號也不會撞
      expect(tl.clips.every((c) => c.id != tl.nextId()), isTrue);
    });

    test('文字跟影片一樣長（或更短）不影響合成', () {
      final tl = base();
      tl.sources.add(MediaSource(
          path: '',
          name: '哈囉',
          kind: ClipKind.text,
          duration: 3600,
          textStyle: TextMark(text: '哈囉')));
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 1,
      ));
      expect(CompPlayer.whyNot(tl), isNull);
    });
  });

  group('覆寫（同軌不重疊）', () {
    TimelineModel base() {
      final tl = TimelineModel();
      tl.sources.add(MediaSource(
          path: '/a.mp4', name: 'a', kind: ClipKind.video, duration: 100));
      // 一段 0~10 秒躺在第 0 軌
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 20,
        trimEnd: 30,
        offset: 0,
        track: 0,
      ));
      return tl;
    }

    test('完全被蓋住＝整段刪除', () {
      final tl = base();
      tl.carveRange(-1, 11, 0);
      expect(tl.clips, isEmpty);
    });

    test('蓋到尾巴＝尾巴被裁掉', () {
      final tl = base();
      tl.carveRange(6, 15, 0);
      final c = tl.clips.single;
      expect(c.offset, 0);
      expect(c.end, closeTo(6, 1e-9));
      expect(c.trimEnd, closeTo(26, 1e-9));
    });

    test('蓋到頭＝頭被裁掉、起點往後移', () {
      final tl = base();
      tl.carveRange(-2, 4, 0);
      final c = tl.clips.single;
      expect(c.offset, closeTo(4, 1e-9));
      expect(c.end, closeTo(10, 1e-9));
      expect(c.trimStart, closeTo(24, 1e-9));
    });

    test('蓋在中段＝切成前後兩半', () {
      final tl = base();
      tl.carveRange(3, 7, 0);
      expect(tl.clips.length, 2);
      final head = tl.clips.firstWhere((c) => c.offset < 1);
      final tail = tl.clips.firstWhere((c) => c.offset > 1);
      expect(head.end, closeTo(3, 1e-9));
      expect(tail.offset, closeTo(7, 1e-9));
      expect(tail.end, closeTo(10, 1e-9));
      // 素材時間也要接得上：頭半段 20~23、尾半段 27~30
      expect(head.trimEnd, closeTo(23, 1e-9));
      expect(tail.trimStart, closeTo(27, 1e-9));
    });

    test('倒轉的片段蓋到中段，兩半的長度也要對', () {
      final tl = base();
      tl.clips.single.reverse = true;
      tl.carveRange(3, 7, 0);
      expect(tl.clips.length, 2);
      final head = tl.clips.firstWhere((c) => c.offset < 1);
      final tail = tl.clips.firstWhere((c) => c.offset > 1);
      expect(head.length, closeTo(3, 1e-9));
      expect(tail.length, closeTo(3, 1e-9));
      // 倒轉：時間軸左緣對素材尾端。頭半段是素材的 27~30、
      // 尾半段是素材的 20~23
      expect(head.trimStart, closeTo(27, 1e-9));
      expect(tail.trimEnd, closeTo(23, 1e-9));
    });

    test('別的軌、放下的自己都不受影響', () {
      final tl = base();
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 2,
        track: 1,
      ));
      tl.carveRange(0, 10, 0, exceptId: tl.clips.first.id);
      expect(tl.clips.length, 2);
    });
  });

  group('整理（closeGaps）', () {
    test('只收中間的空隙，第一段留在原地', () {
      final tl = TimelineModel();
      tl.sources.add(MediaSource(
          path: '/a.mp4', name: 'a', kind: ClipKind.video, duration: 100));
      for (final off in [2.0, 8.0, 15.0]) {
        tl.clips.add(TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 3,
          offset: off,
          track: 0,
        ));
      }
      tl.closeGaps(track: 0);
      final offs = (tl.clips.map((c) => c.offset).toList()..sort());
      // 第一段不動（片頭刻意留白是正常排法），後面接齊
      expect(offs[0], closeTo(2, 1e-9));
      expect(offs[1], closeTo(5, 1e-9));
      expect(offs[2], closeTo(8, 1e-9));
    });
  });

  group('吸附（磁鐵）行為', () {
    /// 一條軸上就這一段，往片頭／片尾附近拖
    TimelineModel oneClip() {
      final tl = TimelineModel();
      tl.sources.add(
        MediaSource(
            path: '/a.mp4', name: 'a', kind: ClipKind.video, duration: 100),
      );
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 12,
        track: 0,
      ));
      return tl;
    }

    test('拖到片頭附近會黏在 0（就算沒有別的素材可以吸）', () {
      final tl = oneClip();
      final moving = tl.clips.first;
      // 60px/秒、離片頭 0.1 秒＝6px，在 16px 的吸附半徑內
      expect(tl.snapOffset(moving, 0.1, 60), 0);
      // 遠到半徑外就不該亂吸
      expect(tl.snapOffset(moving, 1.2, 60), 1.2);
    });

    test('拖到片尾附近會跟現有素材的結尾對齊', () {
      final tl = oneClip();
      tl.clips.add(TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 8,
        offset: 30,
        track: 0,
      ));
      final moving = tl.clips.first; // 長 5 秒
      // 別段的結尾在 38 秒：這一段的結尾要對過去，開頭就是 33
      expect(tl.snapOffset(moving, 33.1, 60), closeTo(33, 0.0001));
    });

    test('時間點吸附也吃得到片頭', () {
      final tl = oneClip();
      // 排除自己之後整條軸沒有別的候選，片頭仍要吸得到
      expect(tl.snapTime(0.1, 60, exceptId: tl.clips.first.id), 0);
    });

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
        final got = tl.snapOffset(moving, want, px);
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
