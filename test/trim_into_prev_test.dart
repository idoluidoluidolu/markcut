// 左把手往前長進前一段：前一段讓位（尾巴縮到新起點），不是頂住不動、
// 也不是把自己往右長。
//
// 實機測試（iOS TestFlight）回報：「在後方的影片往前延伸，應該是前面那部
// 要往前縮起來讓位給他」。fix/overlap 那一版的規則是左把手頂到前一段的
// 尾巴就把起點釘在那裡（floorOnTrack），多拖出來的長度改往右長、把後面
// 的推開——使用者按著的是左把手，前一段一格沒縮，動的反而是自己的右緣。
//
// 這裡釘住模型端的規則（TimelineModel.prevOnTrack／yieldTailBefore）與
// 把手貼齊（snapTrimEdge）：
// (1) 沒碰到前一段不動；碰到就把前一段的尾巴修到新起點，後面那段贏；
// (2) 前一段最短只剩 minLen，再往前就擋住（回傳地板當夾點）；本來就更
//     短的不動、絕不拉長；
// (3) 倒轉／變速的前一段修的是正確的素材端點；
// (4) 疊加物（文字／浮水印／馬賽克）不讓位、自己也沒有前一段；
// (5) 別軌不動；只動前一段的出點，其他欄位原樣；
// (6) 分步跟一次結果相同；結果永遠頭尾相接、不重疊；
// (7) 復原快照還原兩段；
// (8) 貼齊：越過前一段的尾巴之後不吸它（尾巴正跟著把手走），別軌與 0
//     照吸；第一段越過 0 照舊整個放開。
// 編輯器那條線（真的拖把手、素材開頭的上限、復原鍵）在
// video_editor_overlap_test；右把手長進後面那段照舊是推開，見
// track_overlap_test
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';

/// 一支 100 秒的影片來源（index 0）
TimelineModel _base() {
  final tl = TimelineModel();
  tl.sources.add(
    MediaSource(path: '/a.mp4', name: 'a', kind: ClipKind.video, duration: 100),
  );
  return tl;
}

/// 加一段：時間軸 [at]~[at+len]，素材從 [srcAt] 起算（變速就把素材範圍
/// 放大；倒轉時時間軸右緣對應素材的 srcAt）
TimelineClip _add(
  TimelineModel tl,
  double at,
  double len, {
  int track = 0,
  int src = 0,
  double speed = 1,
  double srcAt = 0,
  bool reverse = false,
}) {
  final c = TimelineClip(
    id: tl.nextId(),
    sourceIndex: src,
    trimStart: srcAt,
    trimEnd: srcAt + len * speed,
    offset: at,
    track: track,
    speed: speed,
    reverse: reverse,
  );
  tl.clips.add(c);
  return c;
}

int _addSource(TimelineModel tl, ClipKind kind) {
  final styled =
      kind == ClipKind.text || kind == ClipKind.wm || kind == ClipKind.mosaic;
  tl.sources.add(
    MediaSource(
      path: styled ? '' : '/x.$kind',
      name: 'x',
      kind: kind,
      duration: kind == ClipKind.video || kind == ClipKind.audio ? 100 : 3600,
      textStyle: kind == ClipKind.text ? TextMark(text: '字') : null,
      wmStyle: kind == ClipKind.wm ? WatermarkSettings() : null,
      mosaicStyle: kind == ClipKind.mosaic ? MosaicStyle() : null,
    ),
  );
  return tl.sources.length - 1;
}

/// 編輯器 _trimClip 左把手那幾行的模型版：[c] 的起點想往前到 [want]
///（右緣不動），前一段讓位，讓不到的部分夾在地板。往後拖最多到自己
/// 剩 [minLen]（編輯器的煞車：trimStart 最多到 trimEnd − minSrc）。
/// 回傳實際的起點
double _headTo(TimelineModel tl, TimelineClip c, double want, double minLen) {
  final end = c.end;
  final capped = math.min(want, end - minLen);
  final floor = tl.yieldTailBefore(c, capped, minLen: minLen);
  final at = math.max(floor, capped);
  // 露出／收起的頭換算成素材秒；倒轉片段的時間軸左緣是素材尾
  final d = (c.offset - at) * c.speed;
  if (c.reverse) {
    c.trimEnd += d;
  } else {
    c.trimStart -= d;
  }
  c.offset = at;
  expect(c.end, closeTo(end, 1e-9), reason: '左把手：右緣不動');
  return at;
}

/// 受規則管的片段同軌兩兩比（獨立於 firstOverlapOnTracks 的第二把尺）
void _expectNoOverlap(TimelineModel tl, String where) {
  final lane = [
    for (final c in tl.clips)
      if (tl.exclusiveOnTrack(c)) c,
  ];
  for (var i = 0; i < lane.length; i++) {
    for (var j = i + 1; j < lane.length; j++) {
      final a = lane[i], b = lane[j];
      if (a.track != b.track) continue;
      final overlap = math.min(a.end, b.end) - math.max(a.offset, b.offset);
      expect(
        overlap <= kOverlapEps,
        isTrue,
        reason:
            '$where：軌${a.track} ${a.offset}~${a.end} 跟 '
            '${b.offset}~${b.end} 重疊 $overlap',
      );
    }
  }
  expect(tl.firstOverlapOnTracks(), isNull, reason: where);
}

String _json(TimelineModel tl) =>
    jsonEncode([for (final c in tl.clips) c.toJson()]);

void main() {
  group('prevOnTrack：要讓位的前一段', () {
    test('同軌排在前面、尾巴伸得最遠的那段；第一段沒有', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 4);
      final c = _add(tl, 8, 2);
      expect(tl.prevOnTrack(a), isNull);
      expect(tl.prevOnTrack(b), same(a));
      expect(tl.prevOnTrack(c), same(b));
    });

    test('中間有空隙也算：不必貼著', () {
      final tl = _base();
      final a = _add(tl, 0, 3);
      final b = _add(tl, 5, 3);
      expect(tl.prevOnTrack(b), same(a));
    });

    test('疊加物不算：同軌的文字伸得再遠都不是前一段；文字自己也沒有', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 4);
      final text = _add(tl, 0, 4.8, src: _addSource(tl, ClipKind.text));
      expect(tl.prevOnTrack(b), same(a));
      expect(tl.prevOnTrack(text), isNull);
      final wm = _add(tl, 4, 2, src: _addSource(tl, ClipKind.wm));
      expect(tl.prevOnTrack(wm), isNull);
    });

    test('別軌不算；圖片與聲音跟影片一樣算', () {
      final tl = _base();
      _add(tl, 0, 6, track: 1);
      final img = _add(tl, 0, 4, src: _addSource(tl, ClipKind.image));
      final b = _add(tl, 4, 4);
      expect(tl.prevOnTrack(b), same(img));
      final au = _add(tl, 0, 2, track: 2, src: _addSource(tl, ClipKind.audio));
      final au2 = _add(tl, 2, 2, track: 2, src: au.sourceIndex);
      expect(tl.prevOnTrack(au2), same(au));
    });
  });

  group('yieldTailBefore：前一段讓位', () {
    test('沒碰到前一段的尾巴：什麼都不動，回傳它的尾巴', () {
      final tl = _base();
      final a = _add(tl, 0, 3);
      final b = _add(tl, 5, 3);
      final before = _json(tl);
      expect(tl.yieldTailBefore(b, 4.0), closeTo(3, 1e-12));
      expect(tl.yieldTailBefore(b, 3.0), closeTo(3, 1e-12), reason: '剛好碰到也不動');
      expect(_json(tl), before, reason: '兩段都不動');
      expect(a.end, 3.0);
    });

    test('沒有前一段：回傳 0、什麼都不動', () {
      final tl = _base();
      final a = _add(tl, 2, 3);
      final before = _json(tl);
      expect(tl.yieldTailBefore(a, 1.0), 0.0);
      expect(_json(tl), before);
    });

    test('碰到：前一段的尾巴修到新起點——只動它的出點；後面那段自己不動', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 4, srcAt: 5); // 素材 5~9，前面還有 5 秒可以露
      final bBefore = jsonEncode(b.toJson());
      final floor = tl.yieldTailBefore(b, 3.0);
      expect(floor, closeTo(3, 1e-12));
      expect(a.end, closeTo(3, 1e-12), reason: 'A 的尾巴縮到 3');
      expect(a.trimEnd, closeTo(3, 1e-12), reason: '修的是素材出點');
      expect(a.offset, 0.0, reason: 'A 的起點不動');
      expect(a.trimStart, 0.0, reason: 'A 的素材入點不動');
      expect(jsonEncode(b.toJson()), bBefore, reason: 'B 由呼叫端照地板改，這裡不碰');
      // 呼叫端把 B 的起點放到地板：頭尾相接、不重疊、B 的右緣不動
      _headTo(tl, b, 3.0, kMinClipLen);
      expect(b.offset, closeTo(3, 1e-12));
      expect(b.trimStart, closeTo(4, 1e-12), reason: '多露出 1 秒素材');
      expect(b.end, closeTo(8, 1e-12));
      _expectNoOverlap(tl, '讓位後');
      expect(tl.resolveOverlaps(track: 0), 0, reason: '不需要推任何人');
    });

    test('前一段最短只剩 minLen：再往前就擋住，回傳的地板＝它的起點＋minLen', () {
      final tl = _base();
      final a = _add(tl, 1, 4); // 1~5
      final b = _add(tl, 5, 4, srcAt: 10);
      final floor = tl.yieldTailBefore(b, 0.0, minLen: 0.5);
      expect(floor, closeTo(1.5, 1e-12));
      expect(a.length, closeTo(0.5, 1e-12), reason: 'A 剩最短長度');
      expect(a.offset, 1.0);
      final at = _headTo(tl, b, 0.0, 0.5);
      expect(at, closeTo(1.5, 1e-12), reason: 'B 的起點夾在地板');
      expect(b.trimStart, closeTo(6.5, 1e-12), reason: '只露出讓得出來的 3.5 秒');
      _expectNoOverlap(tl, '讓到最短');
      // 再拖也不會更短
      expect(tl.yieldTailBefore(b, -3.0, minLen: 0.5), closeTo(1.5, 1e-12));
      expect(a.length, closeTo(0.5, 1e-12));
    });

    test('minLen 預設是模型的 kMinClipLen', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 4, srcAt: 10);
      expect(tl.yieldTailBefore(b, -1.0), closeTo(kMinClipLen, 1e-12));
      expect(a.length, closeTo(kMinClipLen, 1e-12));
    });

    test('前一段本來就比 minLen 短：一格不動，也不會被拉長', () {
      final tl = _base();
      final a = _add(tl, 0, 0.2);
      final b = _add(tl, 0.2, 4, srcAt: 10);
      final before = _json(tl);
      expect(tl.yieldTailBefore(b, 0.0, minLen: 0.5), closeTo(0.2, 1e-12));
      expect(_json(tl), before);
      _headTo(tl, b, 0.0, 0.5);
      expect(b.offset, closeTo(0.2, 1e-12));
      expect(a.length, closeTo(0.2, 1e-12), reason: '沒被拉長到 minLen');
      _expectNoOverlap(tl, '前一段本來就短');
    });

    test('倒轉的前一段：時間軸右緣是素材頭，修的是 trimStart', () {
      final tl = _base();
      final a = _add(tl, 0, 4, srcAt: 10, reverse: true); // 素材 10~14 倒著放
      final b = _add(tl, 4, 4, srcAt: 20);
      expect(tl.yieldTailBefore(b, 2.5), closeTo(2.5, 1e-12));
      expect(a.trimStart, closeTo(11.5, 1e-12), reason: '尾巴縮 1.5 秒＝素材頭往後 1.5');
      expect(a.trimEnd, 14.0, reason: '素材尾（時間軸左緣）不動');
      expect(a.end, closeTo(2.5, 1e-12));
      _headTo(tl, b, 2.5, kMinClipLen);
      _expectNoOverlap(tl, '倒轉前一段');
    });

    test('變速的前一段：素材秒照速度換算', () {
      final tl = _base();
      final a = _add(tl, 0, 4, speed: 2); // 素材 0~8 放 4 秒
      final b = _add(tl, 4, 4, srcAt: 20);
      expect(tl.yieldTailBefore(b, 3.0), closeTo(3, 1e-12));
      expect(a.trimEnd, closeTo(6, 1e-12), reason: '時間軸縮 1 秒＝素材縮 2 秒');
      expect(a.end, closeTo(3, 1e-12));
      final slow = _base();
      final s = _add(slow, 0, 4, speed: 0.5); // 素材 0~2 放 4 秒
      final s2 = _add(slow, 4, 4, srcAt: 20);
      expect(slow.yieldTailBefore(s2, 1.0, minLen: 0.5), closeTo(1, 1e-12));
      expect(s.trimEnd, closeTo(0.5, 1e-12));
      expect(s.length, closeTo(1, 1e-12));
    });

    test('後面那段是變速／倒轉的也一樣：讓位只看前一段', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 4, srcAt: 20, speed: 2, reverse: true);
      expect(tl.yieldTailBefore(b, 3.0), closeTo(3, 1e-12));
      expect(a.end, closeTo(3, 1e-12));
      _headTo(tl, b, 3.0, kMinClipLen);
      expect(b.offset, closeTo(3, 1e-12));
      expect(b.trimEnd, closeTo(30, 1e-12), reason: '倒轉：左緣往前 1 秒＝素材尾往後 2 秒');
      _expectNoOverlap(tl, '倒轉變速的後段');
    });

    test('疊加物不讓位、也不會被讓：文字在前面伸得再遠都不動；文字自己沒有前一段', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final text = _add(tl, 0, 4.8, src: _addSource(tl, ClipKind.text));
      final mz = _add(tl, 3, 3, src: _addSource(tl, ClipKind.mosaic));
      final b = _add(tl, 4, 4, srcAt: 20);
      expect(tl.yieldTailBefore(b, 3.0), closeTo(3, 1e-12));
      expect(a.end, closeTo(3, 1e-12), reason: '讓位的是影片');
      expect(text.end, 4.8, reason: '文字不動');
      expect(mz.end, 6.0, reason: '馬賽克不動');
      final before = _json(tl);
      expect(tl.yieldTailBefore(text, 1.0), 0.0, reason: '文字的左把手沒有前一段');
      expect(_json(tl), before, reason: '誰都不動');
    });

    test('別軌不動：同樣排法的另一軌一格都沒變', () {
      final tl = _base();
      _add(tl, 0, 4);
      final b = _add(tl, 4, 4, srcAt: 20);
      final a1 = _add(tl, 0, 4, track: 1);
      final b1 = _add(tl, 4, 4, track: 1, srcAt: 20);
      final before1 = jsonEncode([a1.toJson(), b1.toJson()]);
      tl.yieldTailBefore(b, 2.0);
      _headTo(tl, b, 2.0, kMinClipLen);
      expect(jsonEncode([a1.toJson(), b1.toJson()]), before1);
      _expectNoOverlap(tl, '別軌');
    });

    test('只動前一段的出點：淡出、音量、速度、位置、裁切、鏡像全部原樣', () {
      final tl = _base();
      final a = _add(tl, 0, 4)
        ..fadeIn = 0.5
        ..fadeOut = 1
        ..volume = 0.4
        ..px = 0.3
        ..py = 0.7
        ..scale = 1.4
        ..mirror = true
        ..opacity = 0.6
        ..rotation = 12
        ..cropL = 0.1
        ..cropW = 0.8;
      final b = _add(tl, 4, 4, srcAt: 20);
      final before = a.toJson()..remove('trimEnd');
      tl.yieldTailBefore(b, 2.0);
      final after = a.toJson()..remove('trimEnd');
      expect(after, before);
      expect(a.trimEnd, closeTo(2, 1e-12));
      expect(a.fadeOut, 1.0, reason: '跟自己的右把手修短一樣，淡出留著');
    });

    test('分步跟一次結果相同（跟手勢怎麼拆步無關）', () {
      TimelineModel run(List<double> wants) {
        final tl = _base();
        _add(tl, 0, 4);
        final b = _add(tl, 4.5, 4, srcAt: 20); // 4~4.5 留空隙
        for (final w in wants) {
          _headTo(tl, b, w, 0.3);
          _expectNoOverlap(tl, '往前到 $w');
        }
        return tl;
      }

      final once = run([1.0]);
      final steps = run([4.2, 3.9, 3.0, 2.0, 1.0]);
      // 中途往回拖再往前也一樣（往回時前一段不會跟著長回來）
      final wobble = run([3.0, 3.6, 2.0, 1.0]);
      for (final tl in [steps, wobble]) {
        for (var i = 0; i < 2; i++) {
          expect(tl.clips[i].offset, closeTo(once.clips[i].offset, 1e-9));
          expect(tl.clips[i].end, closeTo(once.clips[i].end, 1e-9));
          expect(tl.clips[i].trimStart, closeTo(once.clips[i].trimStart, 1e-9));
          expect(tl.clips[i].trimEnd, closeTo(once.clips[i].trimEnd, 1e-9));
        }
      }
      expect(once.clips[0].end, closeTo(1, 1e-9));
      expect(once.clips[1].offset, closeTo(1, 1e-9));
    });

    test('往回拖：前一段讓出去的不會自己長回來（那是它自己右把手的事）', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 4, srcAt: 20);
      _headTo(tl, b, 2.0, 0.3);
      expect(a.end, closeTo(2, 1e-12));
      _headTo(tl, b, 3.5, 0.3);
      expect(b.offset, closeTo(3.5, 1e-12));
      expect(a.end, closeTo(2, 1e-12), reason: '2~3.5 變成空隙，A 不跟');
      _expectNoOverlap(tl, '往回');
    });

    test('復原：拍快照→讓位→還原，兩段都回到原樣', () {
      final tl = _base();
      final a = _add(tl, 0, 4)..fadeOut = 0.5;
      final b = _add(tl, 4, 4, srcAt: 20);
      final snap = _json(tl); // 編輯器 _pushUndo 拍的就是整條 clips
      _headTo(tl, b, 1.0, 0.3);
      expect(a.end, closeTo(1, 1e-12));
      expect(b.offset, closeTo(1, 1e-12));
      tl.clips
        ..clear()
        ..addAll([
          for (final j in jsonDecode(snap) as List)
            TimelineClip.fromJson(Map<String, dynamic>.from(j as Map)),
        ]);
      expect(_json(tl), snap);
      expect(tl.clips[0].end, 4.0);
      expect(tl.clips[0].fadeOut, 0.5);
      expect(tl.clips[1].offset, 4.0);
      expect(tl.clips[1].trimStart, 20.0);
    });

    test('不變量：亂拖 200 回合，永遠頭尾相接不重疊、前一段只縮不長、不低於最短', () {
      for (var seed = 0; seed < 200; seed++) {
        final r = math.Random(seed);
        final tl = _base();
        final img = _addSource(tl, ClipKind.image);
        // 三段接在一起，速度／倒轉隨機；B 的素材入點留很多可以露
        final speeds = [0.5, 1.0, 1.3, 2.0];
        final a = _add(
          tl,
          r.nextDouble() * 2,
          1 + r.nextDouble() * 4,
          src: r.nextBool() ? 0 : img,
          speed: speeds[r.nextInt(4)],
          srcAt: 10,
          reverse: r.nextBool(),
        );
        final b = _add(
          tl,
          a.end + (r.nextBool() ? 0 : r.nextDouble()),
          1 + r.nextDouble() * 4,
          speed: speeds[r.nextInt(4)],
          srcAt: 40,
          reverse: r.nextBool(),
        );
        final c = _add(tl, b.end + r.nextDouble(), 2, srcAt: 60);
        final minLen = [0.025, 0.1, 0.5][r.nextInt(3)];
        final aLen0 = a.length;
        final cJson = jsonEncode(c.toJson());
        for (var step = 0; step < 20; step++) {
          final where = 'seed=$seed step=$step';
          final aLen = a.length;
          final want = b.offset + (r.nextDouble() - 0.7) * 3;
          _headTo(tl, b, want, minLen);
          _expectNoOverlap(tl, where);
          expect(a.length <= aLen + 1e-9, isTrue, reason: '$where 前一段長回來了');
          expect(
            a.length >= math.min(minLen, aLen0) - 1e-9,
            isTrue,
            reason: '$where 前一段被修到比最短還短',
          );
          expect(b.offset >= a.end - kOverlapEps, isTrue, reason: where);
          expect(b.length > 0, isTrue, reason: where);
          expect(jsonEncode(c.toJson()), cJson, reason: '$where 後面那段不該動');
          expect(tl.resolveOverlaps(), 0, reason: '$where 讓位後不該還要推');
        }
      }
    });
  });

  group('snapTrimEdge 左把手：前一段讓位時的錨點', () {
    // 60px/秒：半徑 16px ≈ 0.267 秒
    const px = 60.0;

    test('碰到前一段的尾巴之前吸它（接縫才對得準）', () {
      final tl = _base();
      _add(tl, 0, 4);
      final b = _add(tl, 4.5, 4);
      expect(tl.snapTrimEdge(b, 4.2, px, fromLeft: true), closeTo(4.0, 1e-9));
    });

    test('越過前一段的尾巴之後：它的頭尾都不吸（尾巴正跟著把手走）', () {
      final tl = _base();
      _add(tl, 3.8, 0.3); // 很短的前一段：頭 3.8、尾 4.1 都在半徑內
      final b = _add(tl, 4.1, 4);
      expect(tl.snapTrimEdge(b, 4.0, px, fromLeft: true), closeTo(4.0, 1e-9));
      expect(tl.snapTrimEdge(b, 3.85, px, fromLeft: true), closeTo(3.85, 1e-9));
    });

    test('越過之後別軌、疊加物與 0 照吸', () {
      final tl = _base();
      _add(tl, 0, 4);
      final b = _add(tl, 4, 4);
      _add(tl, 0, 3.9, track: 1);
      expect(
        tl.snapTrimEdge(b, 3.95, px, fromLeft: true),
        closeTo(3.9, 1e-9),
        reason: '不吸前一段的 4.0，吸別軌的 3.9',
      );
      _add(tl, 0, 2.7, src: _addSource(tl, ClipKind.text));
      expect(tl.snapTrimEdge(b, 2.6, px, fromLeft: true), closeTo(2.7, 1e-9));
      expect(tl.snapTrimEdge(b, 0.1, px, fromLeft: true), closeTo(0.0, 1e-9));
    });

    test('第一段：越過 0 整個放開（照舊，留給呼叫端算往右長）', () {
      final tl = _base();
      final b = _add(tl, 0, 8);
      _add(tl, 0, 0.1, track: 1);
      expect(tl.snapTrimEdge(b, -0.05, px, fromLeft: true), closeTo(-0.05, 1e-9));
      expect(tl.snapTrimEdge(b, 0.05, px, fromLeft: true), closeTo(0.0, 1e-9));
    });

    test('右把手不受影響：碰到下一段之前吸它、推著走時放開', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      _add(tl, 4.2, 2);
      expect(tl.snapTrimEdge(a, 4.15, px, fromLeft: false), closeTo(4.2, 1e-9));
      expect(tl.snapTrimEdge(a, 4.3, px, fromLeft: false), closeTo(4.3, 1e-9));
    });
  });
}
