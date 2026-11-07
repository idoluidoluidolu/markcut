// 快速 Vlog 的秒數規則（lib/services/quick_vlog.dart）。
//
// 使用者 11-07：「各取兩秒（預設）、可以調整時間跟段落、也可以個別調整
// 影片長度，不卡死全部都要共同秒數」。守的是：
// - 每支取中間、不到就整支
// - 改「每段」只動跟著走的段，個別改過的不動；「全部統一」全部一起改
// - 改完整軌頭尾接齊（不留洞、不重疊、從 0 開始）
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/quick_vlog.dart';

/// 一軌影片，各支長度 [durs]，照 vlog 進場的樣子各取中間 [sec] 秒接好
TimelineModel _vlog(List<double> durs, {double sec = kVlogDefaultSec}) {
  final tl = TimelineModel();
  var at = 0.0;
  for (var i = 0; i < durs.length; i++) {
    tl.sources.add(
      MediaSource(
        path: '/v$i.mp4',
        name: 'v$i',
        kind: ClipKind.video,
        duration: durs[i],
        w: 1920,
        h: 1080,
      ),
    );
    final c = TimelineClip(
      id: tl.nextId(),
      sourceIndex: i,
      trimStart: 0,
      trimEnd: durs[i],
      offset: at,
      track: 0,
    );
    vlogTakeMiddle(c, tl.sources[i], sec);
    tl.clips.add(c);
    at = c.end;
  }
  return tl;
}

/// 整軌頭尾相接、從 0 開始（不變量）
void _expectContiguous(TimelineModel tl) {
  var at = 0.0;
  for (final c in tl.onTrack(0)) {
    expect(c.offset, closeTo(at, 1e-9), reason: '片段 ${c.id} 的起點');
    at = c.end;
  }
}

void main() {
  test('每支取正中間 2 秒，不到 2 秒的整支', () {
    final tl = _vlog([10, 1.2, 3]);
    final segs = vlogSegments(tl);
    expect(segs[0].trimStart, closeTo(4, 1e-9));
    expect(segs[0].trimEnd, closeTo(6, 1e-9));
    expect(segs[1].trimStart, 0);
    expect(segs[1].trimEnd, closeTo(1.2, 1e-9), reason: '不到 2 秒就整支');
    expect(segs[2].trimStart, closeTo(0.5, 1e-9));
    expect(segs[2].trimEnd, closeTo(2.5, 1e-9));
    _expectContiguous(tl);
    expect(tl.duration, closeTo(2 + 1.2 + 2, 1e-9));
  });

  test('改每段：跟著走的換成新長度、中心不動，整軌接齊', () {
    final tl = _vlog([10, 10, 10]);
    final n = vlogApplySeconds(tl, from: 2, to: 3);
    expect(n, 3);
    for (final c in vlogSegments(tl)) {
      expect(c.length, closeTo(3, 1e-9));
      expect((c.trimStart + c.trimEnd) / 2, closeTo(5, 1e-9), reason: '中心不動');
    }
    _expectContiguous(tl);
    vlogApplySeconds(tl, from: 3, to: 1);
    for (final c in vlogSegments(tl)) {
      expect(c.length, closeTo(1, 1e-9));
    }
    _expectContiguous(tl);
  });

  test('個別改過長度的不跟著每段走；全部統一才一起改', () {
    final tl = _vlog([10, 10, 10]);
    final mid = vlogSegments(tl)[1];
    vlogSetLength(mid, tl.sourceOf(mid), 3.5);
    vlogRelay(tl);
    expect(vlogHasCustom(tl, 2), isTrue);

    final n = vlogApplySeconds(tl, from: 2, to: 1.5);
    expect(n, 2, reason: '自訂的那段不算');
    final segs = vlogSegments(tl);
    expect(segs[0].length, closeTo(1.5, 1e-9));
    expect(segs[1].length, closeTo(3.5, 1e-9), reason: '個別改過的不動');
    expect(segs[2].length, closeTo(1.5, 1e-9));
    _expectContiguous(tl);

    vlogApplySeconds(tl, from: 1.5, to: 1.5, all: true);
    for (final c in vlogSegments(tl)) {
      expect(c.length, closeTo(1.5, 1e-9));
    }
    expect(vlogHasCustom(tl, 1.5), isFalse);
    _expectContiguous(tl);
  });

  test('拖滑桿經過自訂段的長度，不會把它捲進來；拖回原值回到原本那一截', () {
    final tl = _vlog([10, 10, 10]);
    final mid = vlogSegments(tl)[1];
    vlogSetLength(mid, tl.sourceOf(mid), 3.5);
    vlogRelay(tl);
    final last = vlogSegments(tl)[2];
    last.trimStart = 8; // 換到靠結尾的那一截
    last.trimEnd = 10;
    final edit = VlogSecondsEdit(tl, from: 2);
    expect(edit.count, 2);
    // 一格一格拖到 5、再拖回 2（中途經過 3.5、也會夾到原片結尾）
    for (var s = 2.1; s <= 5.0001; s += 0.1) {
      edit.apply(s);
    }
    expect(mid.length, closeTo(3.5, 1e-9), reason: '自訂的那段不能半路被捲進來');
    expect(last.trimEnd, closeTo(10, 1e-9));
    for (var s = 4.9; s >= 1.9999; s -= 0.1) {
      edit.apply(s);
    }
    expect(last.trimStart, closeTo(8, 1e-9), reason: '拖回原值要回到原本那一截');
    expect(last.trimEnd, closeTo(10, 1e-9));
    expect(mid.length, closeTo(3.5, 1e-9));
    _expectContiguous(tl);
  });

  test('素材比每段短：算跟著走，每段改短時跟著變短、改長時維持整支', () {
    final tl = _vlog([10, 1.2]);
    final short = vlogSegments(tl)[1];
    expect(vlogFollows(short, tl.sourceOf(short), 2), isTrue);
    expect(vlogHasCustom(tl, 2), isFalse);

    vlogApplySeconds(tl, from: 2, to: 0.8);
    expect(short.length, closeTo(0.8, 1e-9));
    expect((short.trimStart + short.trimEnd) / 2, closeTo(0.6, 1e-9));

    vlogApplySeconds(tl, from: 0.8, to: 5);
    expect(short.length, closeTo(1.2, 1e-9), reason: '原片只有 1.2 秒');
    expect(vlogSegments(tl)[0].length, closeTo(5, 1e-9));
    _expectContiguous(tl);
  });

  test('換過段落（同樣長度）的照樣跟著每段走，從新段落的中心長短', () {
    final tl = _vlog([10]);
    final c = vlogSegments(tl).single;
    c.trimStart = 7;
    c.trimEnd = 9;
    vlogApplySeconds(tl, from: 2, to: 1);
    expect(c.trimStart, closeTo(7.5, 1e-9));
    expect(c.trimEnd, closeTo(8.5, 1e-9));
    // 靠近結尾變長：夾在原片範圍內
    vlogApplySeconds(tl, from: 1, to: 6);
    expect(c.trimEnd, closeTo(10, 1e-9));
    expect(c.trimStart, closeTo(4, 1e-9));
  });

  test('變速的段：每段秒數算時間軸長度', () {
    final tl = _vlog([20, 20]);
    final fast = vlogSegments(tl)[0];
    fast.speed = 2;
    fast.trimEnd = fast.trimStart + 4; // 原片 4 秒、2 倍速＝時間軸 2 秒
    vlogRelay(tl);
    expect(vlogFollows(fast, tl.sourceOf(fast), 2), isTrue);
    vlogApplySeconds(tl, from: 2, to: 3);
    expect(fast.length, closeTo(3, 1e-9));
    expect(fast.srcLength, closeTo(6, 1e-9));
  });

  test('只動影片／圖片段；同軌的聲音、其他軌不動', () {
    final tl = _vlog([10, 10]);
    tl.sources.add(
      MediaSource(
        path: '/m.mp3',
        name: 'm',
        kind: ClipKind.audio,
        duration: 30,
      ),
    );
    final music = TimelineClip(
      id: tl.nextId(),
      sourceIndex: 2,
      trimStart: 0,
      trimEnd: 30,
      offset: 0,
      track: 1,
    );
    tl.clips.add(music);
    vlogApplySeconds(tl, from: 2, to: 4);
    expect(music.length, closeTo(30, 1e-9));
    expect(music.offset, 0);
    expect(vlogSegments(tl).length, 2);
  });

  test('靜態圖片段：從 0 開始取，沒有長度上限', () {
    final tl = TimelineModel();
    tl.sources.add(
      MediaSource(
        path: '/p.jpg',
        name: 'p',
        kind: ClipKind.image,
        duration: 3600,
        w: 100,
        h: 100,
      ),
    );
    final c = TimelineClip(
      id: tl.nextId(),
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 4,
      offset: 0,
      track: 0,
    );
    tl.clips.add(c);
    expect(vlogFollows(c, tl.sources[0], 2), isFalse);
    vlogApplySeconds(tl, from: 2, to: 3, all: true);
    expect(c.trimStart, 0);
    expect(c.trimEnd, closeTo(3, 1e-9));
    expect(vlogMaxLength(c, tl.sources[0]), kVlogMaxSec);
  });

  test('秒數字串與滑桿上限', () {
    expect(vlogSecLabel(2), '2');
    expect(vlogSecLabel(2.5), '2.5');
    expect(vlogSecLabel(2.04), '2');
    expect(vlogSecLabel(0.5), '0.5');
    final tl = _vlog([3, 30]);
    final segs = vlogSegments(tl);
    expect(vlogMaxLength(segs[0], tl.sourceOf(segs[0])), closeTo(3, 1e-9));
    expect(vlogMaxLength(segs[1], tl.sourceOf(segs[1])), kVlogMaxSec);
  });
}
