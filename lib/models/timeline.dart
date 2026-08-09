import 'dart:math' as math;

import 'color_grade.dart';
import 'watermark_settings.dart';

/// 素材種類。軌道本身不分種類，是「素材」有種類之分。
// wm 一定要加在最尾端：kind 是用 index 序列化的，插中間會毀掉舊草稿
enum ClipKind { video, audio, image, text, wm }

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

  MediaSource({
    required this.path,
    required this.name,
    required this.kind,
    required this.duration,
    this.w = 0,
    this.h = 0,
    this.textStyle,
    this.wmStyle,
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

  /// 這個片段的播放速度（1 = 原速）。
  /// 變速會反映在時間軸長度上：2x 的片段佔的軸長是素材長的一半
  double speed;

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
    ColorGrade? color,
  }) : color = color ?? ColorGrade();

  /// 素材端長度（trim 掉頭尾後的原始秒數）
  double get srcLength => math.max(0.0, trimEnd - trimStart);

  /// 時間軸上佔的長度（變速後）
  double get length => srcLength / speed.clamp(0.1, 16.0);

  double get end => offset + length;

  bool covers(double t) => t >= offset && t < end;

  /// 時間軸時間 → 這份素材內部的時間（含變速換算）
  double sourceTimeAt(double t) =>
      trimStart + (t - offset) * speed.clamp(0.1, 16.0);

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
    final list =
        clips.where((c) => sourceOf(c).isOverlay && c.covers(t)).toList()
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

  /// 把中間空掉的軌號補起來（例如整層被搬走之後）
  void compactTracks() {
    final used = clips.map((c) => c.track).toSet().toList()..sort();
    final map = <int, int>{};
    for (var i = 0; i < used.length; i++) {
      map[used[i]] = i;
    }
    for (final c in clips) {
      c.track = map[c.track] ?? c.track;
    }
  }

  /// 在指定時間切開片段，回傳新產生的後半段（切不成回 null）
  TimelineClip? splitAt(TimelineClip c, double t) {
    if (t - c.offset < 0.2 || c.end - t < 0.2) return null;
    final srcT = c.sourceTimeAt(t);
    // 浮水印／文字素材的樣式存在來源上；切開後兩半要各自
    // 一份來源，不然改其中一半的樣式另一半會跟著變
    var srcIdx = c.sourceIndex;
    final src = sources[srcIdx];
    if (src.kind == ClipKind.wm || src.kind == ClipKind.text) {
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
        ),
      );
      srcIdx = sources.length - 1;
    }
    final second = TimelineClip(
      id: nextId(),
      sourceIndex: srcIdx,
      trimStart: srcT,
      trimEnd: c.trimEnd,
      offset: t,
      track: c.track,
      volume: c.volume,
      speed: c.speed, // 切割後兩段維持相同變速
      px: c.px,
      py: c.py,
      scale: c.scale,
      color: c.color.copy(),
      // 淡出屬於「結尾」，跟著後半走；前半的淡出清掉，
      // 不然會在切點處憑空淡出。淡入同理留在前半
      fadeOut: c.fadeOut,
    );
    c.fadeOut = 0;
    c.trimEnd = srcT;
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

  /// 拖曳時的貼齊：吸附到其他片段邊緣、播放頭與 0
  double snapOffset(
    TimelineClip moving,
    double want,
    double playhead,
    double pxPerSec,
  ) {
    // 16px 內就吸附——太小會感覺不到「磁鐵」，
    // 拖到別的片段頭尾附近要有被吸過去黏住的手感
    final threshold = 16 / pxPerSec;
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
