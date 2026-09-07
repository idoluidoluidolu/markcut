// 同一軌永遠不重疊——實機 189 的根因與新規則的行為規格。
//
// 使用者回報：「時間軸素材影片蓋到後面的素材時應該不要覆蓋，要把後面的
// 往後推」「播放指針指到的地方跟螢幕顯示不一致」。實機診斷：軌 0 六段
// 影片彼此重疊（0.00~0.52、0.27~1.65、1.28~2.08、2.08~3.15、3.15~3.68、
// 3.68~4.92），原生合成卻把它們一段接一段排開（…～5.54s，時間軸終點
// 4.92s）——原生端一條時間軸軌道對一條合成軌，同軌撞到的段只能往後排
//（AppDelegate build：putAt = max(at, slot.end)），從第二段起合成秒數就
// 跟時間軸對不上。根因在模型：以前右把手拉長、左把手往前長、變速、貼上
// 都不擋同軌重疊，放下則是覆寫（carveRange 把被壓到的裁掉）。
//
// 這裡釘住：(1) 哪些操作路徑會製造重疊——先照舊做出重疊當證據，再證明
// resolveOverlaps 把它推開；(2) 推開規則本身（推的量＝壓進去的量、只動
// offset）；(3) 放下／貼上的落點規則；(4) 修剪把手的貼齊不吸「會被自己
// 推動的片段」；(5) 不變量：亂做之後同軌兩兩不重疊，推開不換順序不改長度。
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

/// 加一段：時間軸 [at]~[at+len]（素材從 0 起算、變速就把素材範圍放大）
TimelineClip _add(
  TimelineModel tl,
  double at,
  double len, {
  int track = 0,
  int src = 0,
  double speed = 1,
}) {
  final c = TimelineClip(
    id: tl.nextId(),
    sourceIndex: src,
    trimStart: 0,
    trimEnd: len * speed,
    offset: at,
    track: track,
    speed: speed,
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

/// 獨立於 firstOverlapOnTracks 的第二把尺：受規則管的片段同軌兩兩比
void _expectNoOverlap(TimelineModel tl, String where) {
  final lane = [
    for (final c in tl.clips)
      if (tl.exclusiveOnTrack(c)) c,
  ];
  for (var i = 0; i < lane.length; i++) {
    for (var j = i + 1; j < lane.length; j++) {
      final a = lane[i], b = lane[j];
      if (a.track != b.track) continue;
      final overlap =
          math.min(a.end, b.end) - math.max(a.offset, b.offset);
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

/// 跑 resolveOverlaps 並驗它的契約：只動 offset（長度不變）、不換順序、
/// 清單不動、冪等
int _settle(TimelineModel tl, String where, {int? track, int? pinnedId}) {
  final lens = {for (final c in tl.clips) c.id: c.length};
  final order = List.of(tl.clips);
  // 推之前就已經「a 在 b 前面」的同軌兩段，推之後還是
  final before = <(int, int)>[];
  for (final a in tl.clips) {
    for (final b in tl.clips) {
      if (a == b || a.track != b.track) continue;
      if (!tl.exclusiveOnTrack(a) || !tl.exclusiveOnTrack(b)) continue;
      if (a.end <= b.offset + kOverlapEps) before.add((a.id, b.id));
    }
  }
  final moved = tl.resolveOverlaps(track: track, pinnedId: pinnedId);
  _expectNoOverlap(tl, where);
  expect(List.of(tl.clips), order, reason: '$where：推開不該動清單');
  for (final c in tl.clips) {
    expect(c.length, closeTo(lens[c.id]!, 1e-12), reason: '$where：推開改了長度');
  }
  final byId = {for (final c in tl.clips) c.id: c};
  for (final (a, b) in before) {
    expect(
      byId[a]!.end <= byId[b]!.offset + kOverlapEps,
      isTrue,
      reason: '$where：推開把 $a、$b 的先後對調了',
    );
  }
  expect(tl.resolveOverlaps(), 0, reason: '$where：推開不冪等');
  return moved;
}

void main() {
  group('實機 189：軌 0 六段影片彼此重疊', () {
    // 診斷原文的六段
    const spans = [
      (0.00, 0.52),
      (0.27, 1.65),
      (1.28, 2.08),
      (2.08, 3.15),
      (3.15, 3.68),
      (3.68, 4.92),
    ];
    TimelineModel device() {
      final tl = _base();
      for (final (a, b) in spans) {
        _add(tl, a, b - a);
      }
      return tl;
    }

    test('這條時間軸確實同軌重疊（原生端就是為此把它們依序接起來）', () {
      final tl = device();
      final clash = tl.firstOverlapOnTracks();
      expect(clash, isNotNull);
      expect(clash!.$1.offset, 0.0);
      expect(clash.$2.offset, closeTo(0.27, 1e-9));
    });

    test('推開之後：兩兩不重疊、順序長度不變，排法正是原生合成排出來的那串（總長 5.54）', () {
      final tl = device();
      final moved = _settle(tl, '實機 189');
      expect(moved, 5, reason: '第一段不動，其餘五段都被推');
      // 原生診斷：媒0.00~0.52｜0.52~1.90｜1.90~2.70｜2.70~3.77｜3.77~4.30｜4.30~5.54
      const want = [0.00, 0.52, 1.90, 2.70, 3.77, 4.30];
      for (var i = 0; i < spans.length; i++) {
        expect(
          tl.clips[i].offset,
          closeTo(want[i], 1e-9),
          reason: '第 ${i + 1} 段的起點',
        );
        expect(
          tl.clips[i].length,
          closeTo(spans[i].$2 - spans[i].$1, 1e-9),
          reason: '第 ${i + 1} 段的長度不變',
        );
      }
      expect(
        tl.duration,
        closeTo(5.54, 1e-9),
        reason: '時間軸終點現在等於合成總長，指針才對得上畫面',
      );
    });

    test('舊草稿：JSON 讀回來還是重疊的，推開規則一樣適用（載入時正規化）', () {
      final tl = device();
      final json = jsonEncode([for (final c in tl.clips) c.toJson()]);
      final back = _base();
      for (final j in jsonDecode(json) as List) {
        back.clips.add(TimelineClip.fromJson(Map<String, dynamic>.from(j as Map)));
      }
      expect(back.firstOverlapOnTracks(), isNotNull, reason: '讀回來還是重疊的');
      _settle(back, '舊草稿');
      expect(back.duration, closeTo(5.54, 1e-9));
    });
  });

  group('會製造重疊的操作路徑：照舊做→證明重疊→推開', () {
    test('右把手拉長（trimEnd 往後）：長進下一段，下一段與更後面的連鎖推開', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 2);
      final c = _add(tl, 7, 2); // 6~7 留一秒空隙
      a.trimEnd += 2; // 以前的 _trimClip 就這樣直接改，沒人擋
      expect(tl.firstOverlapOnTracks(), isNotNull, reason: '模型以前允許這種重疊');
      _settle(tl, '右把手', track: 0);
      expect(a.end, closeTo(6, 1e-9), reason: '拉長的那段自己不動');
      expect(b.offset, closeTo(6, 1e-9), reason: 'B 被推到 A 的結尾');
      expect(c.offset, closeTo(8, 1e-9), reason: 'B 推進 C 一秒（空隙先吃掉），C 跟著推一秒');
    });

    test('推的量＝壓進去的量：前面有空隙先吃掉，碰到了才推', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 5, 2);
      a.trimEnd += 0.5; // 0~4.5，還沒碰到 B
      expect(_settle(tl, '沒碰到', track: 0), 0);
      expect(b.offset, 5.0, reason: '沒碰到就不推');
      a.trimEnd += 1.0; // 0~5.5，壓進 B 半秒
      expect(_settle(tl, '碰到了', track: 0), 1);
      expect(b.offset, closeTo(5.5, 1e-9), reason: '推半秒，不是把手走的 1.5 秒');
    });

    test('同一幾何一次拉跟分三步拉，結果相同（跟手勢怎麼拆步無關）', () {
      TimelineModel run(List<double> steps) {
        final tl = _base();
        final a = _add(tl, 0, 4);
        _add(tl, 5, 2);
        _add(tl, 7.5, 1);
        for (final s in steps) {
          a.trimEnd += s;
          tl.resolveOverlaps(track: 0);
        }
        return tl;
      }

      final once = run([3]);
      final thrice = run([1, 1, 1]);
      for (var i = 0; i < 3; i++) {
        expect(thrice.clips[i].offset, closeTo(once.clips[i].offset, 1e-9));
      }
      expect(once.clips[1].offset, closeTo(7, 1e-9));
      expect(once.clips[2].offset, closeTo(9, 1e-9));
    });

    test('變速變慢＝變長：後面推開；變快＝變短：留空隙、不動別人', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 2);
      a.speed = 0.5; // 4 秒素材放 8 秒
      expect(tl.firstOverlapOnTracks(), isNotNull);
      _settle(tl, '變慢', track: 0);
      expect(b.offset, closeTo(8, 1e-9));
      a.speed = 2; // 變成 2 秒
      expect(_settle(tl, '變快', track: 0), 0);
      expect(b.offset, closeTo(8, 1e-9), reason: '空隙是銜接（closeGaps）的事，推開不管');
    });

    test('倒轉檔換上（同 offset、新速度）：長度變了就推開', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 2);
      // _swapClip：同一段換成指向倒轉檔的新實例，速度 0.5
      final i = tl.clips.indexOf(a);
      tl.clips[i] = TimelineClip.fromJson({...a.toJson(), 'speed': 0.5});
      _settle(tl, '倒轉檔', track: 0);
      expect(b.offset, closeTo(8, 1e-9));
    });

    test('左把手往前長進前一段：前一段讓位（尾巴縮到新起點），不是頂住往右長', () {
      // 實機測試回報「在後方的影片往前延伸，應該是前面那部要往前縮起來
      // 讓位給他」——這裡以前釘的是「頂到前一段的尾巴就停、多出來的往
      // 右長、C 被推」，現在反過來。規則本身在 trim_into_prev_test
      final tl = _base();
      final a = _add(tl, 0, 4);
      // B 在 5~8，素材用的是 5~8 那段（前面還有 5 秒可以露出來）
      final bb = TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 5,
        trimEnd: 8,
        offset: 5,
        track: 0,
      );
      tl.clips.add(bb);
      final c = _add(tl, 8, 2);
      final text = _addSource(tl, ClipKind.text);
      _add(tl, 0, 4.8, src: text); // 同軌的文字伸到 4.8：不是前一段
      expect(tl.prevOnTrack(bb), same(a));
      expect(tl.prevOnTrack(tl.clips.first), isNull, reason: '第一段沒有前一段');
      // 編輯器 _trimClip 左把手往前拖 2 秒：素材入點 5→3、起點 5→3。
      // 4~5 的空隙先吃掉，再往前的那 1 秒是 A 的尾巴讓出來的
      const ns = 3.0;
      final virtual = bb.offset + (ns - bb.trimStart) / bb.speed;
      final floor = tl.yieldTailBefore(bb, virtual, minLen: 0.3);
      bb.trimStart = ns;
      bb.offset = math.max(floor, virtual);
      expect(bb.offset, closeTo(3, 1e-9));
      expect(a.end, closeTo(3, 1e-9), reason: 'A 的尾巴縮到 B 的新起點');
      expect(bb.length, closeTo(5, 1e-9), reason: '露出來的素材確實多了 2 秒');
      expect(bb.end, closeTo(8, 1e-9), reason: '起點往前、結尾不動');
      expect(_settle(tl, '左把手讓位', track: 0), 0, reason: '沒有人需要被推');
      expect(c.offset, 8.0, reason: 'C 不動');
    });

    test('切割：兩半相接，不需要推', () {
      final tl = _base();
      final a = _add(tl, 0, 6);
      final b = _add(tl, 6, 2);
      final second = tl.splitAt(a, 2.5)!;
      expect(_settle(tl, '切割', track: 0), 0);
      expect(second.offset, 2.5);
      expect(b.offset, 6.0);
    });

    test('銜接開著：先推開再補洞，整軌接齊、沒有重疊；關著：空隙保留', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      final b = _add(tl, 4, 2);
      final c = _add(tl, 8, 2); // 6~8 空隙
      a.trimEnd += 1; // 壓進 B 一秒
      _settle(tl, '推開', track: 0);
      expect(b.offset, closeTo(5, 1e-9));
      expect(c.offset, 8.0, reason: '銜接關著：B 還沒碰到 C，7~8 的空隙留著');
      // 銜接開著＝推完再 closeGaps（_autoTidyIfOn）
      final removed = tl.closeGaps(track: 0, fromZero: true);
      expect(removed, closeTo(1, 1e-9));
      expect(c.offset, closeTo(7, 1e-9));
      _expectNoOverlap(tl, '銜接後');
    });

    test('carveRange 不再是放下的行為：模型裡留著但推開不裁不刪', () {
      final tl = _base();
      final a = _add(tl, 0, 10);
      final p = _add(tl, 3, 2); // 放到 A 中段
      tl.resolveOverlaps(track: 0, pinnedId: p.id);
      expect(tl.clips.length, 2, reason: '沒有切成三段');
      expect(a.srcLength, 10.0, reason: 'A 一格都沒被裁');
    });
  });

  group('放下／貼上的落點（placeOffsetOnTrack ＋ pin 住推開）', () {
    /// A 0~4、B 4~8、C 8~10 頭尾相接
    TimelineModel packed() {
      final tl = _base();
      _add(tl, 0, 4);
      _add(tl, 4, 4);
      _add(tl, 8, 2);
      return tl;
    }

    /// 把長 [len] 的新段放到 [want]，回傳它
    TimelineClip drop(TimelineModel tl, double want, double len) {
      final p = TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: len,
        offset: want,
        track: 0,
      );
      p.offset = tl.placeOffsetOnTrack(p, want, 0);
      tl.clips.add(p);
      _settle(tl, '放下在 $want', track: 0, pinnedId: p.id);
      return p;
    }

    test('落在別段前半：吸到它的頭，插在它前面，它跟後面的都推開', () {
      final tl = packed();
      final p = drop(tl, 1.0, 2);
      expect(p.offset, 0.0);
      expect(tl.clips[0].offset, closeTo(2, 1e-9), reason: 'A 被推到 P 後面');
      expect(tl.clips[1].offset, closeTo(6, 1e-9));
      expect(tl.clips[2].offset, closeTo(10, 1e-9));
    });

    test('落在別段後半：吸到它的尾，接在它後面，只推更後面的', () {
      final tl = packed();
      final p = drop(tl, 3.0, 2);
      expect(p.offset, 4.0);
      expect(tl.clips[0].offset, 0.0, reason: 'A 不動');
      expect(tl.clips[1].offset, closeTo(6, 1e-9), reason: 'B 被推');
      expect(tl.clips[2].offset, closeTo(10, 1e-9));
    });

    test('正中央算後半；剛好放在邊界上不算「落在身上」，pin 住就插在那裡', () {
      final tl = packed();
      expect(tl.placeOffsetOnTrack(tl.clips[1], 2.0, 0), 4.0, reason: 'A 的正中央→尾');
      final p = drop(tl, 4.0, 1); // B 的頭
      expect(p.offset, 4.0);
      expect(tl.clips[1].offset, closeTo(5, 1e-9), reason: 'B 讓開');
    });

    test('落在空隙：照原意圖；身體壓到下一段的部分才推', () {
      final tl = _base();
      _add(tl, 0, 4);
      final c = _add(tl, 5, 2); // 4~5 空隙
      final p = drop(tl, 4.5, 2); // 4.5~6.5 壓進 C 1.5 秒
      expect(p.offset, 4.5);
      expect(c.offset, closeTo(6.5, 1e-9));
    });

    test('落在軌道尾端之後：照原意圖，誰都不動', () {
      final tl = packed();
      final p = drop(tl, 12.0, 2);
      expect(p.offset, 12.0);
      expect(tl.clips.take(3).map((c) => c.offset), [0.0, 4.0, 8.0]);
    });

    test('負的想放位置夾到 0', () {
      final tl = packed();
      expect(tl.placeOffsetOnTrack(tl.clips[2], -3, 0), 0.0);
    });

    test('搬到別軌：只看目標軌的片段', () {
      final tl = packed();
      final b = tl.clips[1];
      expect(tl.placeOffsetOnTrack(b, 1.0, 1), 1.0, reason: '第 1 軌是空的');
    });
  });

  group('不受規則管的片段（文字／浮水印・貼圖／馬賽克）', () {
    test('疊加物可以疊：不被推、也不推別人', () {
      final tl = _base();
      final text = _addSource(tl, ClipKind.text);
      final wm = _addSource(tl, ClipKind.wm);
      final mz = _addSource(tl, ClipKind.mosaic);
      _add(tl, 0, 3, src: text);
      _add(tl, 1, 3, src: text);
      _add(tl, 0, 5, src: wm);
      _add(tl, 2, 2, src: mz);
      final v = _add(tl, 0, 5); // 影片跟它們同軌
      expect(_settle(tl, '疊加物'), 0);
      v.trimEnd = 20; // 影片蓋過所有疊加物
      expect(_settle(tl, '影片伸過疊加物'), 0);
      expect(tl.placeOffsetOnTrack(tl.clips[1], 1.5, 0), 1.5, reason: '疊加物放哪就哪');
    });

    test('筆刷馬賽克：一筆一段、同軌同時間疊好幾段，原樣保留', () {
      final tl = _base();
      _add(tl, 0, 10);
      for (var i = 0; i < 5; i++) {
        _add(tl, 2, 3, src: _addSource(tl, ClipKind.mosaic), track: 1);
      }
      expect(_settle(tl, '筆刷'), 0);
      expect(tl.onTrack(1).every((c) => c.offset == 2.0), isTrue);
    });

    test('圖片與聲音受規則管', () {
      final tl = _base();
      final img = _addSource(tl, ClipKind.image);
      final au = _addSource(tl, ClipKind.audio);
      _add(tl, 0, 4, src: img);
      final i2 = _add(tl, 3, 4, src: img);
      _add(tl, 0, 4, src: au, track: 1);
      final a2 = _add(tl, 1, 4, src: au, track: 1);
      expect(_settle(tl, '圖片聲音'), 2);
      expect(i2.offset, closeTo(4, 1e-9));
      expect(a2.offset, closeTo(4, 1e-9));
    });

    test('指到不存在素材的片段不算（載入時它們會被剔除）', () {
      final tl = _base();
      tl.clips.add(
        TimelineClip(id: 9, sourceIndex: 7, trimStart: 0, trimEnd: 5, offset: 0, track: 0),
      );
      expect(tl.exclusiveOnTrack(tl.clips.single), isFalse);
      expect(tl.resolveOverlaps(), 0);
    });
  });

  group('修剪把手的貼齊（snapTrimEdge）', () {
    // 60px/秒：半徑 16px ≈ 0.267 秒
    const px = 60.0;

    test('右把手：碰到下一段的頭之前會吸它、也吸 0 與別軌', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      _add(tl, 4.2, 2);
      _add(tl, 0, 4.1, track: 1);
      expect(tl.snapTrimEdge(a, 4.15, px, fromLeft: false), closeTo(4.2, 1e-9));
      expect(tl.snapTrimEdge(a, 4.05, px, fromLeft: false), closeTo(4.1, 1e-9), reason: '別軌照吸');
    });

    test('右把手推著下一段走時：不吸被推的那些段（吸了會黏在原地一格一格跳）', () {
      final tl = _base();
      final a = _add(tl, 0, 4);
      _add(tl, 4, 0.1); // 很短的 B，尾巴 4.1 就在半徑內
      _add(tl, 4.1, 2); // C
      // raw 越過 B 的頭（接觸點）＝正在推：B、C 都不是錨點
      expect(tl.snapTrimEdge(a, 4.05, px, fromLeft: false), closeTo(4.05, 1e-9));
      expect(tl.snapTrimEdge(a, 4.3, px, fromLeft: false), closeTo(4.3, 1e-9));
    });

    test('左把手：越過前一段的尾巴（它正在讓位）就不吸它，沒越過照吸它的尾巴', () {
      final tl = _base();
      _add(tl, 0, 4);
      final b = _add(tl, 4, 4);
      expect(tl.snapTrimEdge(b, 3.9, px, fromLeft: true), closeTo(3.9, 1e-9), reason: '越過：不吸前一段');
      expect(tl.snapTrimEdge(b, 4.1, px, fromLeft: true), closeTo(4.0, 1e-9), reason: '沒越過：吸它的尾巴');
      b.offset = 4.5; // 前面留空隙
      expect(tl.snapTrimEdge(b, 4.2, px, fromLeft: true), closeTo(4.0, 1e-9), reason: '靠近前一段的尾巴：吸');
      // 越過之後別軌照吸（規則細節在 trim_into_prev_test）
      _add(tl, 0, 3.9, track: 1);
      expect(tl.snapTrimEdge(b, 3.95, px, fromLeft: true), closeTo(3.9, 1e-9), reason: '不吸前一段的 4.0，吸別軌的 3.9');
    });

    test('左把手：第一段的地板是 0，越過 0 不夾（留給呼叫端算往右長）', () {
      final tl = _base();
      final b = _add(tl, 0, 8);
      expect(tl.snapTrimEdge(b, -0.1, px, fromLeft: true), closeTo(-0.1, 1e-9));
      expect(tl.snapTrimEdge(b, 0.1, px, fromLeft: true), closeTo(0.0, 1e-9));
    });

    test('疊加物的把手：同軌別段全是錨點（照舊）', () {
      final tl = _base();
      _add(tl, 0, 4);
      final t = _add(tl, 4, 3, src: _addSource(tl, ClipKind.text));
      expect(tl.snapTrimEdge(t, 3.9, px, fromLeft: true), closeTo(4.0, 1e-9));
    });
  });

  group('不變量：亂做之後同軌兩兩不重疊', () {
    test('隨機操作 300 回合 × 300 步（含放下、把手、變速、切割、銜接）', () {
      for (var seed = 0; seed < 300; seed++) {
        final r = math.Random(seed);
        final tl = _base();
        final srcOf = {
          for (final k in ClipKind.values) k: _addSource(tl, k),
        };
        TimelineClip pick() => tl.clips[r.nextInt(tl.clips.length)];
        for (var step = 0; step < 300; step++) {
          final op = tl.clips.isEmpty ? 0 : r.nextInt(9);
          final where = 'seed=$seed step=$step op=$op';
          switch (op) {
            case 0: // 新加／貼上：吸邊、pin 住推開
              final kind = ClipKind.values[r.nextInt(ClipKind.values.length)];
              final c = TimelineClip(
                id: tl.nextId(),
                sourceIndex: srcOf[kind]!,
                trimStart: 0,
                trimEnd: 0.5 + r.nextDouble() * 8,
                offset: 0,
                track: r.nextInt(4),
                speed: [0.5, 1.0, 2.0][r.nextInt(3)],
              );
              c.offset = tl.placeOffsetOnTrack(c, r.nextDouble() * 40, c.track);
              tl.clips.add(c);
              _settle(tl, where, track: c.track, pinnedId: c.id);
            case 1: // 右把手
              final c = pick();
              final dur = tl.sourceOf(c).duration;
              c.trimEnd = (c.trimEnd + (r.nextDouble() - 0.5) * 6).clamp(
                c.trimStart + 0.1,
                math.max(c.trimStart + 0.1, dur),
              );
              _settle(tl, where, track: c.track);
            case 2: // 左把手（前一段讓位：尾巴修到新起點，讓到最短就擋住）
              final c = pick();
              var ns = (c.trimStart + (r.nextDouble() - 0.5) * 6)
                  .clamp(0.0, math.max(0.0, c.trimEnd - 0.1))
                  .toDouble();
              var virtual = c.offset + (ns - c.trimStart) / c.speed;
              if (tl.prevOnTrack(c) != null) {
                final floor = tl.yieldTailBefore(c, virtual, minLen: 0.1);
                if (virtual < floor) {
                  ns = c.trimStart + (floor - c.offset) * c.speed;
                  virtual = floor;
                }
              }
              c.trimStart = ns;
              c.offset = math.max(0.0, virtual);
              _settle(tl, where, track: c.track);
            case 3: // 變速
              final c = pick();
              c.speed = [0.25, 0.5, 1.0, 2.0, 4.0][r.nextInt(5)];
              _settle(tl, where, track: c.track);
            case 4: // 搬動（含換軌）
              final c = pick();
              final t = r.nextInt(4);
              c.offset = tl.placeOffsetOnTrack(c, r.nextDouble() * 40, t);
              c.track = t;
              _settle(tl, where, track: t, pinnedId: c.id);
            case 5: // 切割：不該需要推
              final c = pick();
              if (tl.splitAt(c, c.offset + r.nextDouble() * c.length) != null) {
                expect(tl.resolveOverlaps(track: c.track), 0, reason: '$where 切割後要推＝切歪了');
              }
            case 6: // 刪除
              tl.clips.remove(pick());
            case 7: // 銜接：本身不能製造重疊
              tl.closeGaps(
                track: r.nextBool() ? r.nextInt(4) : null,
                fromZero: r.nextBool(),
              );
              expect(tl.resolveOverlaps(), 0, reason: '$where 銜接製造了重疊');
            case 8: // 整段位移（模型工具；負的會撞回前面）
              tl.shiftAfter(r.nextInt(4), r.nextDouble() * 30, (r.nextDouble() - 0.5) * 20);
              tl.resolveOverlaps();
          }
          _expectNoOverlap(tl, where);
          for (final c in tl.clips) {
            expect(c.offset >= 0 && c.offset.isFinite, isTrue, reason: where);
            expect(c.length > 0, isTrue, reason: '$where 空片段');
          }
        }
      }
    });
  });
}
