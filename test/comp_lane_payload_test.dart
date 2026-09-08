// 合成播放器 payload 的「對時」契約：送給原生的每一段時間範圍 = 片段的
// offset~end，而且同軌兩兩不重疊。
//
// 原生端 build 是照 offset 排的（同軌片段之間的縫用空段／填充補），
// 但同軌撞在一起時只能把後者往後排（putAt = max(at, slot.end)）——
// 實機 189 的「軌0：媒0.00~0.52｜媒0.52~1.90｜…」就是這樣來的：時間軸
// 第二段 0.27~1.65 被排到 0.52~1.90，總長 5.54 對時間軸 4.92，播放指針
// 指的地方跟畫面從第二段起就對不上。Dart 端 payload 的 offset/start/end/
// speed 都是照片段送的，所以只要模型保證同軌不重疊，原生端就不會走到
// 那條路；這裡釘住這兩件事，外加漏網時的哨兵（診斷筆記）。
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/diagnostics.dart';

void main() {
  const ch = MethodChannel('markcut/comp');
  late List<Map<Object?, Object?>> sent;

  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    sent = [];
    Diag.reset();
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          sent.add(call.arguments as Map<Object?, Object?>);
          return <String, dynamic>{'textureId': 1, 'duration': 8.0};
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
  });

  /// 給 workPath＝不會去探測 HDR，測試不碰檔案系統
  TimelineModel base() {
    final tl = TimelineModel();
    tl.sources.add(
      MediaSource(
        path: '/a.mp4',
        name: 'a',
        kind: ClipKind.video,
        duration: 100,
        workPath: '/a.work.mp4',
      ),
    );
    return tl;
  }

  TimelineClip add(
    TimelineModel tl,
    double at,
    double len, {
    int track = 0,
    double speed = 1,
  }) {
    final c = TimelineClip(
      id: tl.nextId(),
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: len * speed,
      offset: at,
      track: track,
      speed: speed,
    );
    tl.clips.add(c);
    return c;
  }

  /// payload 的一段在合成裡佔的範圍：offset ~ offset + (end-start)/speed
  ///（原生端 insertTimeRange(range, at: offset) 再 scaleTimeRange 到
  /// (end-start)/speed）
  (double, double) rangeOf(Map<Object?, Object?> m) {
    final off = (m['offset'] as num).toDouble();
    final len = ((m['end'] as num) - (m['start'] as num)) / (m['speed'] as num);
    return (off, off + len);
  }

  /// 契約本體：每一段對得上片段的 offset~end；同軌依序、不重疊
  void expectPayloadMatches(TimelineModel tl, Map<Object?, Object?> payload) {
    final clips = payload['clips'] as List<Object?>;
    final vids =
        [
          for (final c in tl.clips)
            if (tl.sourceOf(c).isVideo) c,
        ]..sort((a, b) {
          final t = a.offset.compareTo(b.offset);
          return t != 0 ? t : a.track.compareTo(b.track);
        });
    expect(clips.length, vids.length);
    final reach = <int, double>{};
    for (var i = 0; i < vids.length; i++) {
      final m = clips[i] as Map<Object?, Object?>;
      final c = vids[i];
      final (s, e) = rangeOf(m);
      expect(m['track'], c.track);
      expect(s, closeTo(c.offset, 1e-9), reason: '第 $i 段的起點要等於片段 offset');
      expect(e, closeTo(c.end, 1e-9), reason: '第 $i 段的終點要等於片段 end');
      expect(
        s >= (reach[c.track] ?? 0) - 1e-9,
        isTrue,
        reason: '第 $i 段（軌${c.track}）壓到前一段：原生端會把它往後排',
      );
      reach[c.track] = math.max(reach[c.track] ?? 0, e);
    }
  }

  /// 實機 189 的六段
  TimelineModel device() {
    final tl = base();
    for (final (a, b) in const [
      (0.00, 0.52),
      (0.27, 1.65),
      (1.28, 2.08),
      (2.08, 3.15),
      (3.15, 3.68),
      (3.68, 4.92),
    ]) {
      add(tl, a, b - a);
    }
    return tl;
  }

  test('實機 189：推開之後送出去的每一段 = 片段的 offset~end，同軌不重疊，總長 5.54', () async {
    final tl = device();
    tl.resolveOverlaps();
    expect(await CompPlayer.build(tl), isNotNull);
    expectPayloadMatches(tl, sent.single);
    final last = rangeOf(
      (sent.single['clips'] as List).last as Map<Object?, Object?>,
    );
    expect(last.$2, closeTo(5.54, 1e-9));
    expect(tl.duration, closeTo(5.54, 1e-9), reason: '時間軸終點＝合成總長');
    expect(Diag.report(), isNot(contains('同軌重疊')), reason: '哨兵不該叫');
  });

  test('沒推開就送（漏網）：payload 本身照片段送、原生端會依序排——哨兵寫進診斷', () async {
    final tl = device();
    expect(await CompPlayer.build(tl), isNotNull);
    // Dart 端沒有偷改：offset 還是時間軸的 0.27（錯位是原生端 putAt 造成的）
    final second = (sent.single['clips'] as List)[1] as Map<Object?, Object?>;
    expect(second['offset'], closeTo(0.27, 1e-9));
    expect(
      Diag.report(),
      contains('合成 payload 有同軌重疊：軌0 0.00~0.52 壓到 0.27~1.65'),
    );
  });

  test('變速片段：(end-start)/speed 就是時間軸長度，推開後也對得上', () async {
    final tl = base();
    add(tl, 0, 2, speed: 2); // 素材 4 秒放 2 秒
    add(tl, 1, 3, speed: 0.5); // 素材 1.5 秒放 3 秒，壓到第一段
    add(tl, 3, 1);
    tl.resolveOverlaps();
    expect(await CompPlayer.build(tl), isNotNull);
    expectPayloadMatches(tl, sent.single);
    expect(tl.clips[1].offset, closeTo(2, 1e-9));
    expect(tl.clips[2].offset, closeTo(5, 1e-9));
  });

  test('多軌：每一軌各自不重疊，不同軌可以疊（子母畫面）', () async {
    final tl = base();
    add(tl, 0, 4);
    add(tl, 3, 4); // 壓到 → 推到 4
    add(tl, 1, 2, track: 1); // 別軌，疊在上面沒問題
    tl.resolveOverlaps();
    expect(await CompPlayer.build(tl), isNotNull);
    expectPayloadMatches(tl, sent.single);
    expect(tl.onTrack(0)[1].offset, closeTo(4, 1e-9));
    expect(tl.onTrack(1).single.offset, 1.0);
  });

  test('隨機時間軸：推開之後 payload 一律照 offset、同軌不重疊', () async {
    final r = math.Random(189);
    for (var round = 0; round < 150; round++) {
      final tl = base();
      final n = 1 + r.nextInt(8);
      for (var i = 0; i < n; i++) {
        add(
          tl,
          r.nextDouble() * 20,
          0.2 + r.nextDouble() * 6,
          track: r.nextInt(3),
          speed: [0.5, 1.0, 2.0][r.nextInt(3)],
        );
      }
      tl.resolveOverlaps();
      sent.clear();
      expect(await CompPlayer.build(tl), isNotNull, reason: 'round=$round');
      expectPayloadMatches(tl, sent.single);
    }
  });
  test(
    'square canvas and trimmed GIF timing survive native composition',
    () async {
      final tl = base();
      add(tl, 0, 8, track: 1);
      tl.sources.add(
        MediaSource(
          path: '/clip.gif',
          isGif: true,
          name: 'gif',
          kind: ClipKind.image,
          duration: 5,
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 1,
          trimStart: 1.2,
          trimEnd: 3.2,
          offset: 2,
          track: 0,
          speed: 2,
        ),
      );
      expect(await CompPlayer.build(tl, canvasAspect: 1), isNotNull);
      expect(sent.single['canvasAspect'], 1);
      final gif = (sent.single['stills'] as List).single as Map;
      expect(gif['sourceStart'], 1.2);
      expect(gif['sourceRate'], 2);
      expect(gif['start'], 2);
      expect(gif['end'], 3);
    },
  );
}
