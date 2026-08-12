import 'dart:math' as math;

import 'color_grade.dart';
import 'mosaic.dart';
import 'watermark_settings.dart';

export 'mosaic.dart';

/// 素材種類。軌道本身不分種類，是「素材」有種類之分。
// wm 一定要加在最尾端：kind 是用 index 序列化的，插中間會毀掉舊草稿
enum ClipKind { video, audio, image, text, wm, mosaic }

/// 一份匯入的素材（影片或音訊），可被多個片段引用
class MediaSource {
  final String path; // 手機：檔案路徑；Web：blob URL
  String name; // 文字素材的內容存在這裡（可編輯）
  final ClipKind kind;
  final int w; // 影片/圖片的像素尺寸
  final int h;
  final double duration;

  /// 文字素材的樣式（字型、顏色、效果；位置用 clip 的 px/py）
  TextMark? textStyle;

  /// 浮水印素材的完整設定（文字＋Logo；位置存在設定自己的 x/y 裡）。
  /// 這讓浮水印變成一般的時間軸元素：可多軌、可切割、可移動
  WatermarkSettings? wmStyle;

  /// 馬賽克素材的樣式（濃度、像素化/模糊/黑色）
  MosaicStyle? mosaicStyle;

  /// 這份素材是「倒轉版」時，記下它是從哪個原始檔的哪一段做出來的。
  /// 使用者把速度拉回正的時，靠這些資訊還原回原始素材
  final String? revOf;
  final double revStart;
  final double revEnd;

  MediaSource({
    required this.path,
    required this.name,
    required this.kind,
    required this.duration,
    this.w = 0,
    this.h = 0,
    this.textStyle,
    this.wmStyle,
    this.mosaicStyle,
    this.revOf,
    this.revStart = 0,
    this.revEnd = 0,
  });

  bool get isVideo => kind == ClipKind.video;

  /// 疊在畫面上的靜態素材（圖片、文字、浮水印）
  bool get isOverlay =>
      kind == ClipKind.image || kind == ClipKind.text || kind == ClipKind.wm;
  double get aspect => (w == 0 || h == 0) ? 16 / 9 : w / h;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'kind': kind.index,
    'w': w,
    'h': h,
    'duration': duration,
    if (textStyle != null) 'textStyle': textStyle!.toJson(),
    if (wmStyle != null) 'wmStyle': wmStyle!.toJson(),
    if (mosaicStyle != null) 'mosaicStyle': mosaicStyle!.toJson(),
    if (revOf != null) 'revOf': revOf,
    if (revOf != null) 'revStart': revStart,
    if (revOf != null) 'revEnd': revEnd,
  };

  factory MediaSource.fromJson(Map<String, dynamic> j) => MediaSource(
    path: j['path'] ?? '',
    name: j['name'] ?? '',
    // % 防護：新版種類存進草稿後被舊版打開也不至於整包炸掉
    kind: ClipKind.values[((j['kind'] ?? 0) as int) % ClipKind.values.length],
    w: (j['w'] ?? 0) as int,
    h: (j['h'] ?? 0) as int,
    duration: (j['duration'] ?? 0).toDouble(),
    textStyle: j['textStyle'] == null
        ? null
        : TextMark.fromJson(Map<String, dynamic>.from(j['textStyle'] as Map)),
    wmStyle: j['wmStyle'] == null
        ? null
        : WatermarkSettings.fromJson(
            Map<String, dynamic>.from(j['wmStyle'] as Map),
          ),
    mosaicStyle: j['mosaicStyle'] == null
        ? null
        : MosaicStyle.fromJson(
            Map<String, dynamic>.from(j['mosaicStyle'] as Map),
          ),
    revOf: j['revOf'] as String?,
    revStart: (j['revStart'] ?? 0).toDouble(),
    revEnd: (j['revEnd'] ?? 0).toDouble(),
  );
}

/// 時間軸上的一個片段。
/// 軌道是通用圖層：影片、音樂都能放在任何一軌。
/// track 0 = 最上層（畫面以最上層的影片為準；聲音則是全部混音）。
class TimelineClip {
  final int id;
  final int sourceIndex;
  double trimStart;
  double trimEnd;
  double offset; // 在時間軸上的起點（秒，原速）
  int track;
  double volume;

  // 畫面變形（影片/圖片/文字圖層）：中心位置 0~1、縮放（1 = 貼合畫布）
  double px;
  double py;
  double scale;

  // 淡入淡出（時間軸秒；影片淡畫面、聲音淡音量）
  double fadeIn;
  double fadeOut;

  /// 這個片段的播放速度（1 = 原速）。永遠是正數，
  /// 「倒著放」是另外用 reverse 表示（負速度會讓長度計算整組壞掉）
  double speed;

  /// 倒轉播放（速度滑桿拉到負的那半邊）
  bool reverse;

  /// 調色（跟照片編輯共用同一個模型）
  final ColorGrade color;

  TimelineClip({
    required this.id,
    required this.sourceIndex,
    required this.trimStart,
    required this.trimEnd,
    required this.offset,
    required this.track,
    this.volume = 1.0,
    this.px = 0.5,
    this.py = 0.5,
    this.scale = 1.0,
    this.fadeIn = 0,
    this.fadeOut = 0,
    this.speed = 1.0,
    this.reverse = false,
    ColorGrade? color,
  }) : color = color ?? ColorGrade();

  /// 素材端長度（trim 掉頭尾後的原始秒數）
  double get srcLength => math.max(0.0, trimEnd - trimStart);

  /// 時間軸上佔的長度（變速後）
  double get length => srcLength / speed.clamp(0.1, 16.0);

  double get end => offset + length;

  bool covers(double t) => t >= offset && t < end;

  /// 時間軸時間 → 這份素材內部的時間（含變速換算）。
  /// 倒轉時從素材的尾巴往回走
  double sourceTimeAt(double t) {
    final d = (t - offset) * speed.clamp(0.1, 16.0);
    return reverse ? trimEnd - d : trimStart + d;
  }

  /// 淡入淡出在 t 時刻的係數（0~1）
  double fadeFactorAt(double t) {
    var f = 1.0;
    if (fadeIn > 0.01) f = math.min(f, (t - offset) / fadeIn);
    if (fadeOut > 0.01) f = math.min(f, (end - t) / fadeOut);
    return f.clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceIndex': sourceIndex,
    'trimStart': trimStart,
    'trimEnd': trimEnd,
    'offset': offset,
    'track': track,
    'volume': volume,
    'px': px,
    'py': py,
    'scale': scale,
    'fadeIn': fadeIn,
    'fadeOut': fadeOut,
    'speed': speed,
    'reverse': reverse,
    // 調色的鍵維持扁平，舊草稿讀得回來
    ...color.toJson(),
  };

  factory TimelineClip.fromJson(Map<String, dynamic> j) => TimelineClip(
    id: (j['id'] ?? 0) as int,
    sourceIndex: (j['sourceIndex'] ?? 0) as int,
    trimStart: (j['trimStart'] ?? 0).toDouble(),
    trimEnd: (j['trimEnd'] ?? 0).toDouble(),
    offset: (j['offset'] ?? 0).toDouble(),
    track: (j['track'] ?? 0) as int,
    volume: (j['volume'] ?? 1.0).toDouble(),
    px: (j['px'] ?? 0.5).toDouble(),
    py: (j['py'] ?? 0.5).toDouble(),
    scale: (j['scale'] ?? 1.0).toDouble(),
    fadeIn: (j['fadeIn'] ?? 0).toDouble(),
    fadeOut: (j['fadeOut'] ?? 0).toDouble(),
    speed: (j['speed'] ?? 1.0).toDouble(),
    reverse: (j['reverse'] ?? false) as bool,
    color: ColorGrade.fromJson(j),
  );

  TimelineClip copy() => TimelineClip.fromJson(toJson());
}

/// 整條時間軸的狀態與操作
class TimelineModel {
  final List<MediaSource> sources = [];
  final List<TimelineClip> clips = [];
  int _idSeq = 0;

  int nextId() => _idSeq++;

  /// 有內容的軌數（畫面上還會多留一條空軌）
  int get usedTracks {
    var n = 0;
    for (final c in clips) {
      if (c.track + 1 > n) n = c.track + 1;
    }
    return n;
  }

  double get duration {
    var d = 0.0;
    for (final c in clips) {
      if (c.end > d) d = c.end;
    }
    return d;
  }

  MediaSource sourceOf(TimelineClip c) => sources[c.sourceIndex];

  /// 某時刻該顯示哪個影片片段。
  /// 上層優先；同一層疊在一起時，後放進來的蓋住先放的。
  TimelineClip? videoAt(double t) {
    TimelineClip? best;
    for (final c in clips) {
      if (!sourceOf(c).isVideo || !c.covers(t)) continue;
      if (best == null || c.track <= best.track) best = c;
    }
    return best;
  }

  /// 某時刻所有蓋在畫面上的影片片段，由下層到上層
  List<TimelineClip> videosAt(double t) {
    final list = clips.where((c) => sourceOf(c).isVideo && c.covers(t)).toList()
      ..sort((a, b) {
        final k = b.track.compareTo(a.track);
        return k != 0 ? k : clips.indexOf(a).compareTo(clips.indexOf(b));
      });
    return list;
  }

  /// 還原草稿/復原快照後，確保之後配的 id 不會撞號
  void ensureIdAbove(int maxUsed) {
    if (_idSeq <= maxUsed) _idSeq = maxUsed + 1;
  }

  /// 某時刻蓋在畫面上的圖片／文字片段，由下層到上層排序
  List<TimelineClip> overlaysAt(double t) {
    // 馬賽克也算畫面上的覆蓋物（預覽要畫）；
    // 但不進 isOverlay——匯出端對 overlay 的輸入映射是另一套
    final list = clips
        .where(
          (c) =>
              (sourceOf(c).isOverlay ||
                  sourceOf(c).kind == ClipKind.mosaic) &&
              c.covers(t),
        )
        .toList()
          ..sort((a, b) {
            final k = b.track.compareTo(a.track); // track 大的是下層，先畫
            return k != 0 ? k : clips.indexOf(a).compareTo(clips.indexOf(b));
          });
    return list;
  }

  /// 某軌上的片段，依時間排序
  List<TimelineClip> onTrack(int track) {
    final list = clips.where((c) => c.track == track).toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));
    return list;
  }

  /// 同軌上第一個影片片段之後的空位（用來把新影片接在後面）
  double appendPointOnTrack(int track) {
    var end = 0.0;
    for (final c in clips) {
      if (c.track == track && c.end > end) end = c.end;
    }
    return end;
  }

  /// 找一條完全空著的軌（給音樂用）；沒有就回傳最後一軌的下一軌
  int firstFreeTrack() => usedTracks;

  /// 這個片段搬到 track 之後，會不會跟該軌現有的片段時間重疊
  bool overlapsOnTrack(TimelineClip clip, int track) {
    for (final c in clips) {
      if (c.id == clip.id || c.track != track) continue;
      if (c.offset < clip.end && c.end > clip.offset) return true;
    }
    return false;
  }

  /// 一鍵補洞：把片段依時間排好、頭尾接齊，中間的空隙全部收掉。
  /// track 給 null 就整理所有軌道。回傳實際收掉的總秒數
  double closeGaps({int? track}) {
    final targets = track != null
        ? [track]
        : (clips.map((c) => c.track).toSet().toList()..sort());
    var removed = 0.0;
    for (final t in targets) {
      var cursor = 0.0;
      for (final c in onTrack(t)) {
        // 只補「空隙」，不動刻意重疊的片段——重疊時 c.offset < cursor，
        // 照原本的寫法會把它往後推開，還把負數算進「收掉的秒數」
        final gap = c.offset - cursor;
        if (gap > 0) {
          removed += gap;
          c.offset = cursor;
        }
        if (c.end > cursor) cursor = c.end;
      }
    }
    return removed;
  }

  /// 整條軌道刪掉（軌上所有片段一起移除），下面的軌往上遞補。
  /// 回傳「舊軌號 → 新軌號」對照，呼叫端要拿它重映靜音之類的軌號狀態
  Map<int, int> removeTrack(int track) {
    clips.removeWhere((c) => c.track == track);
    final map = <int, int>{};
    for (final c in clips) {
      final old = c.track;
      if (old > track) c.track--;
      map[old] = c.track;
    }
    return map;
  }

  /// 把中間空掉的軌號補起來（例如整層被搬走之後）。
  /// 同樣回傳「舊軌號 → 新軌號」對照
  Map<int, int> compactTracks() {
    final used = clips.map((c) => c.track).toSet().toList()..sort();
    final map = <int, int>{};
    for (var i = 0; i < used.length; i++) {
      map[used[i]] = i;
    }
    for (final c in clips) {
      c.track = map[c.track] ?? c.track;
    }
    return map;
  }

  /// 在指定時間切開片段，回傳新產生的後半段（切不成回 null）
  TimelineClip? splitAt(TimelineClip c, double t) {
    if (t - c.offset < 0.2 || c.end - t < 0.2) return null;
    final srcT = c.sourceTimeAt(t);
    // 浮水印／文字素材的樣式存在來源上；切開後兩半要各自
    // 一份來源，不然改其中一半的樣式另一半會跟著變
    var srcIdx = c.sourceIndex;
    final src = sources[srcIdx];
    if (src.kind == ClipKind.wm ||
        src.kind == ClipKind.text ||
        src.kind == ClipKind.mosaic) {
      sources.add(
        MediaSource(
          path: src.path,
          name: src.name,
          kind: src.kind,
          w: src.w,
          h: src.h,
          duration: src.duration,
          textStyle: src.textStyle?.copy(),
          wmStyle: src.wmStyle?.copy(),
          mosaicStyle: src.mosaicStyle?.copy(),
        ),
      );
      srcIdx = sources.length - 1;
    }
    // 倒轉片段的時間軸左緣對應素材的尾端，所以前後兩半要反過來配；
    // 照正向切會讓兩半的長度對調，切完直接重疊
    final second = TimelineClip(
      id: nextId(),
      sourceIndex: srcIdx,
      trimStart: c.reverse ? c.trimStart : srcT,
      trimEnd: c.reverse ? srcT : c.trimEnd,
      offset: t,
      track: c.track,
      volume: c.volume,
      speed: c.speed, // 切割後兩段維持相同變速
      reverse: c.reverse,
      px: c.px,
      py: c.py,
      scale: c.scale,
      color: c.color.copy(),
      // 淡出屬於「結尾」，跟著後半走；前半的淡出清掉，
      // 不然會在切點處憑空淡出。淡入同理留在前半
      fadeOut: c.fadeOut,
    );
    c.fadeOut = 0;
    if (c.reverse) {
      c.trimStart = srcT;
    } else {
      c.trimEnd = srcT;
    }
    clips.add(second);
    return second;
  }

  /// 把某軌上排在指定片段之後的片段整體位移（刪除/插入時保持接續）
  void shiftAfter(int track, double fromTime, double delta) {
    for (final c in clips) {
      if (c.track == track && c.offset >= fromTime - 0.001) {
        c.offset = math.max(0.0, c.offset + delta);
      }
    }
  }

  /// 把一個時間點吸到最近的參考點（別的片段的頭尾、播放頭、0）。
  /// 修剪把手、浮水印範圍都用這個，手感跟拖曳整段一致
  double snapTime(
    double want,
    double playhead,
    double pxPerSec, {
    int? exceptId,
    double radiusPx = 16,
    double maxSec = 0.5,
  }) {
    // 吸附半徑（像素）＋秒數上限（縮到很小時 16px 可能是十幾秒，
    // 不設上限整條軸都在吸）。播放頭用自己的一組參數
    final threshold = math.min(radiusPx / pxPerSec, maxSec);
    final candidates = <double>[0, playhead];
    for (final c in clips) {
      if (c.id == exceptId) continue;
      candidates.addAll([c.offset, c.end]);
    }
    var best = want;
    var bestDist = threshold;
    for (final cand in candidates) {
      if (cand < 0) continue;
      final d = (cand - want).abs();
      if (d < bestDist) {
        bestDist = d;
        best = cand;
      }
    }
    return math.max(0.0, best);
  }

  /// 修剪把手的貼齊（吸到別的片段，不吸自己）
  double snapEdge(
    TimelineClip moving,
    double want,
    double playhead,
    double pxPerSec,
  ) => snapTime(want, playhead, pxPerSec, exceptId: moving.id);

  /// 拖曳時的貼齊：吸附到其他片段邊緣、播放頭與 0
  double snapOffset(
    TimelineClip moving,
    double want,
    double playhead,
    double pxPerSec,
  ) {
    // 跟 snapTime 同一組手感參數
    final threshold = math.min(16 / pxPerSec, 0.5);
    final len = moving.length;
    final candidates = <double>[0, playhead, playhead - len];
    for (final c in clips) {
      if (c.id == moving.id) continue;
      candidates.addAll([c.offset, c.end, c.offset - len, c.end - len]);
    }
    var best = want;
    var bestDist = threshold;
    for (final cand in candidates) {
      if (cand < 0) continue;
      final d = (cand - want).abs();
      if (d < bestDist) {
        bestDist = d;
        best = cand;
      }
    }
    return math.max(0.0, best);
  }
}
