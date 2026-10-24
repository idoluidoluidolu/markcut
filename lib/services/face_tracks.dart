import 'dart:math' as math;

import 'face_detect.dart';

export 'face_detect.dart' show FaceBox, FaceSample;

/// 軌跡上的一個點：那一秒，臉的中心與寬高（0~1，已經放大到蓋得住頭）
class FaceKey {
  final double t, cx, cy, w, h;

  const FaceKey(this.t, this.cx, this.cy, this.w, this.h);

  Map<String, double> toJson() => {'t': t, 'x': cx, 'y': cy, 'w': w, 'h': h};

  static FaceKey fromJson(Map<String, dynamic> j) => FaceKey(
    (j['t'] as num).toDouble(),
    (j['x'] as num).toDouble(),
    (j['y'] as num).toDouble(),
    (j['w'] as num).toDouble(),
    (j['h'] as num).toDouble(),
  );
}

/// 一個人：從出現到離開，臉跟著走的那條路
class FaceTrack {
  /// 第幾個人（照出現先後，從 1 開始）
  final int id;

  /// 時間由小到大。頭尾各多一點：臉剛轉過來、要轉走的那幾格偵測器常常
  /// 慢半拍，寧可多蓋
  final List<FaceKey> keys;

  /// 拿來當頭像的那一格（臉最大的那一次）
  final FaceKey best;

  FaceTrack(this.id, this.keys, this.best);

  double get start => keys.first.t;
  double get end => keys.last.t;

  /// [t] 秒時臉在哪（中心、寬高，0~1）。超出這條軌跡回 null。
  /// 兩個點之間照時間線性內插——偵測是每秒十格上下，中間的格子靠這個
  FaceKey? at(double t) {
    if (keys.isEmpty || t < start || t > end) return null;
    var lo = 0, hi = keys.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (keys[mid].t <= t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final a = keys[lo], b = keys[hi];
    if (b.t <= a.t) return a;
    final f = ((t - a.t) / (b.t - a.t)).clamp(0.0, 1.0);
    double l(double x, double y) => x + (y - x) * f;
    return FaceKey(t, l(a.cx, b.cx), l(a.cy, b.cy), l(a.w, b.w), l(a.h, b.h));
  }
}

/// 把一格一格的偵測結果串成「每個人一條軌跡」。
///
/// - 配對：每一格的框跟上一格還活著的軌跡比，重疊夠多（或中心夠近）
///   就是同一個人；配不到的開新軌跡
/// - [maxGap] 秒內沒再出現還算同一個人（轉頭、被擋一下）；中間的空檔
///   靠內插補上，不會有幾格露臉
/// - 只出現 [minHits] 次以下的丟掉：多半是誤判（衣服花紋、背景海報）
/// - 去抖：中心與大小做小窗平均，框不會一格一格地跳
/// - 放大：偵測框大約是眉毛到下巴，往外放一圈、往上挪一點（跟照片的
///   faceMosaic 同一組倍率），頭髮邊、額頭才蓋得到
/// - 頭尾各延長 [lead]／[tail] 秒：偵測器常常在臉剛轉過來、要轉走的
///   那幾格慢半拍
List<FaceTrack> buildFaceTracks(
  List<FaceSample> samples, {
  double maxGap = 1.0,
  int minHits = 2,
  double lead = 0.2,
  double tail = 0.3,
  double? duration,
}) {
  final sorted = [...samples]..sort((a, b) => a.t.compareTo(b.t));
  final open = <_Raw>[];
  final done = <_Raw>[];

  for (final s in sorted) {
    // 太久沒出現的先收起來
    for (final r in [...open]) {
      if (s.t - r.lastT > maxGap) {
        open.remove(r);
        done.add(r);
      }
    }
    // 所有「軌跡×這一格的框」配對照分數排，貪心配：分數最高的先配
    final pairs = <(double, _Raw, int)>[];
    for (final r in open) {
      final p = r.predict(s.t);
      for (var i = 0; i < s.faces.length; i++) {
        final score = _matchScore(p, s.faces[i]);
        if (score > 0) pairs.add((score, r, i));
      }
    }
    pairs.sort((a, b) => b.$1.compareTo(a.$1));
    final usedTrack = <_Raw>{};
    final usedFace = <int>{};
    for (final (_, r, i) in pairs) {
      if (usedTrack.contains(r) || usedFace.contains(i)) continue;
      usedTrack.add(r);
      usedFace.add(i);
      r.add(s.t, s.faces[i]);
    }
    for (var i = 0; i < s.faces.length; i++) {
      if (!usedFace.contains(i)) open.add(_Raw()..add(s.t, s.faces[i]));
    }
  }
  done.addAll(open);

  final kept = done.where((r) => r.hits.length >= minHits).toList()
    ..sort((a, b) => a.hits.first.$1.compareTo(b.hits.first.$1));
  final out = <FaceTrack>[];
  for (var n = 0; n < kept.length; n++) {
    final keys = _smooth(kept[n].hits).map(_cover).toList();
    var best = keys.first;
    for (final k in keys) {
      if (k.w * k.h > best.w * best.h) best = k;
    }
    // 頭尾延長：拿第一格／最後一格的位置撐著
    final first = keys.first, last = keys.last;
    final s0 = math.max(0.0, first.t - lead);
    final e1 = duration == null
        ? last.t + tail
        : math.min(duration, last.t + tail);
    if (s0 < first.t) {
      keys.insert(0, FaceKey(s0, first.cx, first.cy, first.w, first.h));
    }
    if (e1 > last.t) {
      keys.add(FaceKey(e1, last.cx, last.cy, last.w, last.h));
    }
    out.add(FaceTrack(n + 1, keys, best));
  }
  return out;
}

/// 同一個人的可能性：重疊程度為主；完全沒重疊（動得快、偵測隔得遠）
/// 就看中心距離，在一個臉寬以內給一點分。0＝不可能是同一個人
double _matchScore(FaceBox a, FaceBox b) {
  final l = math.max(a.x, b.x), t = math.max(a.y, b.y);
  final r = math.min(a.x + a.w, b.x + b.w),
      btm = math.min(a.y + a.h, b.y + b.h);
  if (r > l && btm > t) {
    final inter = (r - l) * (btm - t);
    final iou = inter / (a.w * a.h + b.w * b.h - inter);
    if (iou >= 0.15) return 1 + iou;
  }
  final dx = (a.x + a.w / 2) - (b.x + b.w / 2);
  final dy = (a.y + a.h / 2) - (b.y + b.h / 2);
  final dist = math.sqrt(dx * dx + dy * dy);
  final size = math.max(math.max(a.w, a.h), math.max(b.w, b.h));
  // 大小差太多（遠的路人跟近的主角）不配
  final ratio = (a.w * a.h) / (b.w * b.h);
  if (ratio > 4 || ratio < 0.25) return 0;
  return dist < size ? 1 - dist / size : 0;
}

/// 中心與大小做三點平均（頭尾兩點照舊），去掉偵測框一格一格的抖動
List<(double, FaceBox)> _smooth(List<(double, FaceBox)> hits) {
  if (hits.length < 3) return hits;
  final out = <(double, FaceBox)>[hits.first];
  for (var i = 1; i < hits.length - 1; i++) {
    final a = hits[i - 1].$2, b = hits[i].$2, c = hits[i + 1].$2;
    double avg(double x, double y, double z) => (x + 2 * y + z) / 4;
    final w = avg(a.w, b.w, c.w), h = avg(a.h, b.h, c.h);
    final cx = avg(a.x + a.w / 2, b.x + b.w / 2, c.x + c.w / 2);
    final cy = avg(a.y + a.h / 2, b.y + b.h / 2, c.y + c.h / 2);
    out.add((hits[i].$1, FaceBox(cx - w / 2, cy - h / 2, w, h)));
  }
  out.add(hits.last);
  return out;
}

/// 偵測框 → 要蓋的範圍（跟照片的 faceMosaic 同一組倍率：寬 ×1.3、
/// 高 ×1.45、中心往上挪框高的 8%）
FaceKey _cover((double, FaceBox) hit) {
  final (t, f) = hit;
  return FaceKey(
    t,
    f.x + f.w / 2,
    f.y + f.h / 2 - f.h * 0.08,
    f.w * 1.3,
    f.h * 1.45,
  );
}

/// 還在長的一條：配到的每一次偵測（時間、框）
class _Raw {
  final hits = <(double, FaceBox)>[];

  double get lastT => hits.last.$1;

  void add(double t, FaceBox f) => hits.add((t, f));

  /// [t] 秒時大概在哪：照最近兩次的速度往前推（快速走動的人，
  /// 隔 0.1 秒就可能整張臉移出上一格的框）
  FaceBox predict(double t) {
    final last = hits.last.$2;
    if (hits.length < 2) return last;
    final (t0, a) = hits[hits.length - 2];
    final (t1, b) = hits.last;
    final dt = t1 - t0;
    if (dt <= 0) return last;
    final k = ((t - t1) / dt).clamp(0.0, 3.0);
    return FaceBox(b.x + (b.x - a.x) * k, b.y + (b.y - a.y) * k, b.w, b.h);
  }
}
