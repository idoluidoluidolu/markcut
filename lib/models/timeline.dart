import 'dart:math' as math;

import 'color_grade.dart';
import 'mosaic.dart';
import 'watermark_settings.dart';

export 'mosaic.dart';

/// 素材種類。軌道本身不分種類，是「素材」有種類之分。
// wm 一定要加在最尾端：kind 是用 index 序列化的，插中間會毀掉舊草稿
/// 片段（與浮水印範圍）修剪得到的最短長度，單位秒。
///
/// 本來寫死 0.3 秒：放大到看得見毫秒了，把手還是拖不動——想切出
/// 一個兩三格的瞬間根本做不到。30ms 在 30fps 大約是 1 格，
/// 編碼器也吃得下
const double kMinClipLen = 0.025;

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

  /// 這份浮水印素材其實是一張貼圖。
  ///
  /// 畫法與匯出跟浮水印素材完全一樣（整版透明 PNG，見 overlayPngs），
  /// 所以不另立一種 kind——差別只在「使用者眼中它是什麼」：點下去
  /// 開貼圖自己的調整視窗，不是整套浮水印面板；選取時畫框
  bool isSticker;

  /// 工作檔：系統的硬體管線轉出來的 1080p SDR 版本（見 WorkFiles）。
  ///
  /// 預覽、拖曳抽幀、縮圖一律走它。iPhone 預設錄 4K HLG，拿原檔來播
  /// 等於每個片段都養一顆 4K HDR 解碼器，三段就開始掉格；而且工作檔的
  /// HDR→SDR 是系統轉的，跟匯出的成品同一份素材，顏色不會兩套。
  ///
  /// null＝還沒轉好（或平台不支援），這時一律退回原檔——工作檔是加速，
  /// 不是必要條件，所以進場當下就能播，轉好了再換過去
  String? workPath;

  /// 預覽／抽幀要用的路徑
  String get previewPath => workPath ?? path;

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
    this.workPath,
    this.textStyle,
    this.wmStyle,
    this.mosaicStyle,
    this.revOf,
    this.revStart = 0,
    this.revEnd = 0,
    this.isSticker = false,
  });

  bool get isVideo => kind == ClipKind.video;

  /// 同一份素材、換一個實體檔。快速匯出把來源換成工作檔時用：
  /// 其他欄位照抄（w/h 留原始值，只拿來算比例與上限，不影響輸出尺寸）
  MediaSource withPath(String p) => MediaSource(
    path: p,
    name: name,
    kind: kind,
    duration: duration,
    w: w,
    h: h,
    textStyle: textStyle,
    wmStyle: wmStyle,
    mosaicStyle: mosaicStyle,
    isSticker: isSticker,
    revOf: revOf,
    revStart: revStart,
    revEnd: revEnd,
  );

  /// 疊在畫面上的靜態素材（圖片、文字、浮水印）
  bool get isOverlay =>
      kind == ClipKind.image || kind == ClipKind.text || kind == ClipKind.wm;
  double get aspect => (w == 0 || h == 0) ? 16 / 9 : w / h;

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'kind': kind.index,
    if (isSticker) 'sticker': true,
    'w': w,
    'h': h,
    'duration': duration,
    if (workPath != null) 'workPath': workPath,
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
    isSticker: j['sticker'] == true,
    w: (j['w'] ?? 0) as int,
    h: (j['h'] ?? 0) as int,
    duration: (j['duration'] ?? 0).toDouble(),
    workPath: j['workPath'] as String?,
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
/// 編號越大＝疊得越上面（track 0 是最底下的主軌），跟時間軸上看到的
/// 順序一致，也跟剪映／Premiere 一致：新加的素材放到編號最大的一軌，
/// 就是「蓋在最上面、不會被別人壓住」。聲音則是全部混音。
class TimelineClip {
  /// 可改：載入時發現撞號會就地換新號（見 fixDuplicateIds）
  int id;
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

  /// 左右鏡像。自拍的畫面、有字的招牌常常要翻回來
  bool mirror;

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
    this.mirror = false,
    ColorGrade? color,
  }) : color = color ?? ColorGrade();

  /// 素材端長度（trim 掉頭尾後的原始秒數）
  double get srcLength => math.max(0.0, trimEnd - trimStart);

  /// 時間軸上佔的長度（變速後）
  double get length => srcLength / speed.clamp(0.1, 16.0);

  double get end => offset + length;

  bool covers(double t) => t >= offset && t < end;

  /// 畫面用的覆蓋判定：播到最後停在總長那一點時，[covers] 對每個片段
  /// 都不成立（結尾是開區間），畫面就整片黑。這裡讓「剛好停在結尾」
  /// 的那一刻仍算最後一格，播完保留最後一幀
  bool coversForDisplay(double t) => t >= offset && t <= end;

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
    'mirror': mirror,
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
    // 舊草稿可能存了 >1 的音量（以前滑桿開到 200%）。
    // 夾回 1.0：不夾的話 UI 顯示 100% 但匯出還在放大，改也改不掉
    volume: (j['volume'] ?? 1.0).toDouble().clamp(0.0, 1.0),
    px: (j['px'] ?? 0.5).toDouble(),
    py: (j['py'] ?? 0.5).toDouble(),
    scale: (j['scale'] ?? 1.0).toDouble(),
    fadeIn: (j['fadeIn'] ?? 0).toDouble(),
    fadeOut: (j['fadeOut'] ?? 0).toDouble(),
    speed: (j['speed'] ?? 1.0).toDouble(),
    reverse: (j['reverse'] ?? false) as bool,
    mirror: (j['mirror'] ?? false) as bool,
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
  /// 上層優先（編號大的在上）；同一層疊在一起時，後放進來的蓋住先放的。
  TimelineClip? videoAt(double t) {
    TimelineClip? best;
    for (final c in clips) {
      if (!sourceOf(c).isVideo || !c.coversForDisplay(t)) continue;
      if (best == null || c.track >= best.track) best = c;
    }
    return best;
  }

  /// 某時刻所有蓋在畫面上的影片片段，由下層到上層（編號小的先）
  List<TimelineClip> videosAt(double t) {
    final list =
        clips
            .where((c) => sourceOf(c).isVideo && c.coversForDisplay(t))
            .toList()
          ..sort((a, b) {
            final k = a.track.compareTo(b.track);
            return k != 0 ? k : clips.indexOf(a).compareTo(clips.indexOf(b));
          });
    return list;
  }

  /// 還原草稿/復原快照後，確保之後配的 id 不會撞號
  void ensureIdAbove(int maxUsed) {
    if (_idSeq <= maxUsed) _idSeq = maxUsed + 1;
  }

  /// 載入後的體檢：撞號的片段就地換新號，回傳修了幾個。
  ///
  /// id 撞號的專案（舊版本的 bug 存進草稿後就跟著專案一輩子）會讓
  /// 「選一個片段、兩條軌的標籤一起亮」，而且所有照 id 找片段的操作
  /// 都可能找錯對象。先把序號墊到最高之上再補號，補的號才不會再撞
  int fixDuplicateIds() {
    var maxId = -1;
    for (final c in clips) {
      if (c.id > maxId) maxId = c.id;
    }
    ensureIdAbove(maxId);
    final seen = <int>{};
    var fixed = 0;
    for (final c in clips) {
      if (!seen.add(c.id)) {
        c.id = nextId();
        seen.add(c.id);
        fixed++;
      }
    }
    return fixed;
  }

  /// 某時刻蓋在畫面上的圖片／文字片段，由下層到上層排序
  List<TimelineClip> overlaysAt(double t) {
    // 馬賽克也算畫面上的覆蓋物（預覽要畫）；
    // 但不進 isOverlay——匯出端對 overlay 的輸入映射是另一套
    final list =
        clips
            .where(
              (c) =>
                  (sourceOf(c).isOverlay ||
                      sourceOf(c).kind == ClipKind.mosaic) &&
                  c.coversForDisplay(t),
            )
            .toList()
          ..sort((a, b) {
            final k = a.track.compareTo(b.track); // track 小的是下層，先畫
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
  /// 把 [moving] 放到 [track] 的 [want] 位置時，避開既有素材的落點。
  ///
  /// 同一軌上的素材不該互相覆蓋——蓋住的那段等於憑空消失，時間軸上
  /// 還看不出來。想放的位置有人佔著時，滑到最近的空位：往前貼到那段
  /// 的頭、或往後貼到那段的尾，取離原本意圖比較近的一邊。
  /// 兩邊都塞不下就接到整軌的最後面
  double freeOffsetOnTrack(TimelineClip moving, double want, int track) {
    final len = moving.length;
    if (len <= 0) return math.max(0, want);
    final others = [
      for (final c in clips)
        if (c.id != moving.id && c.track == track) c,
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    if (others.isEmpty) return math.max(0, want);

    // 0.001 的容差：頭尾剛好相接不算重疊
    bool fits(double at) {
      if (at < -0.001) return false;
      for (final c in others) {
        if (at < c.end - 0.001 && at + len > c.offset + 0.001) return false;
      }
      return true;
    }

    final start = math.max(0.0, want);
    if (fits(start)) return start;

    // 候選：貼在每一段的前面或後面，挑離原意圖最近而且真的塞得下的
    final cands = <double>[];
    for (final c in others) {
      cands
        ..add(c.offset - len)
        ..add(c.end);
    }
    cands.removeWhere((v) => v < 0 || !fits(v));
    if (cands.isEmpty) return appendPointOnTrack(track);
    cands.sort((a, b) => (a - start).abs().compareTo((b - start).abs()));
    return cands.first;
  }

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
      final list = onTrack(t);
      if (list.isEmpty) continue;
      // 從第一段自己的位置起算：整理是「把中間的空隙收掉」，
      // 不是把整軌拖回 0 秒——片頭刻意留白（等音樂進來）是常見排法，
      // 一開自動整理就被吸到最開始等於這個排法直接不能用
      var cursor = list.first.offset;
      for (final c in list) {
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

  /// 把 [a, b) 這段時間在 [track] 上清出來：蓋到誰就把誰裁掉。
  ///
  /// 同一軌的素材不互相重疊——放下去壓到別人時，被壓住的部分直接消失
  /// （跟主流剪輯 App 的覆寫行為一致）：完全被蓋住的整段刪除、蓋到頭尾
  /// 的把那一側裁掉、蓋在中段的切成前後兩半。[exceptId] 是正在放下的
  /// 那一段自己
  void carveRange(double a, double b, int track, {int? exceptId}) {
    if (b - a < 0.001) return;
    final victims = [
      for (final c in clips)
        if (c.id != exceptId &&
            c.track == track &&
            c.offset < b - 0.001 &&
            c.end > a + 0.001)
          c,
    ];
    for (final c in victims) {
      final headLen = a - c.offset;
      final tailLen = c.end - b;
      // 剩不到 0.05 秒的碎屑不留：看不到、點不到，只會卡整理
      if (headLen < 0.05 && tailLen < 0.05) {
        clips.remove(c);
        continue;
      }
      // 先把兩個切點換算回素材時間，再動 trim——動了就換算不回來了
      final srcA = c.sourceTimeAt(a);
      final srcB = c.sourceTimeAt(b);
      if (headLen >= 0.05 && tailLen >= 0.05) {
        // 蓋在中段：切成頭尾兩段（來源複製規則跟 splitAt 同一套——
        // 樣式類素材兩半要各自一份來源，改一半才不會動到另一半）
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
        clips.add(
          TimelineClip(
            id: nextId(),
            sourceIndex: srcIdx,
            trimStart: c.reverse ? c.trimStart : srcB,
            trimEnd: c.reverse ? srcB : c.trimEnd,
            offset: b,
            track: c.track,
            volume: c.volume,
            speed: c.speed,
            reverse: c.reverse,
            mirror: c.mirror,
            px: c.px,
            py: c.py,
            scale: c.scale,
            fadeOut: c.fadeOut,
            color: c.color.copy(),
          ),
        );
        if (c.reverse) {
          c.trimStart = srcA;
        } else {
          c.trimEnd = srcA;
        }
        c.fadeOut = 0; // 切口不淡出，跟切割一致
        continue;
      }
      if (headLen >= 0.05) {
        // 只蓋到尾巴
        if (c.reverse) {
          c.trimStart = srcA;
        } else {
          c.trimEnd = srcA;
        }
        c.fadeOut = 0;
      } else {
        // 只蓋到頭
        if (c.reverse) {
          c.trimEnd = srcB;
        } else {
          c.trimStart = srcB;
        }
        c.offset = b;
        c.fadeIn = 0;
      }
    }
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

  /// 把一個時間點吸到最近的素材頭尾。
  /// 修剪把手、浮水印範圍都用這個，手感跟拖曳整段一致。
  ///
  /// 吸素材的頭尾，外加片頭（0 秒）這個固定錨點。
  ///
  /// 播放頭不吸：它跟著手指跑，是個位置一直在變的吸附點，滑到哪吸到哪
  /// ＝「亂吸」。0 秒本來也拿掉了（想說第一段素材的頭就在那裡），但排除
  /// 掉自己之後（[exceptId]），或整條軸上就這一段時，片頭附近一個候選
  /// 都沒有，手一放就停在離片頭一點點的怪地方
  double snapTime(
    double want,
    double pxPerSec, {
    int? exceptId,
    double radiusPx = 16,
    double maxSec = 0.5,
  }) {
    // 吸附半徑（像素）＋秒數上限（縮到很小時 16px 可能是十幾秒，
    // 不設上限整條軸都在吸）
    final threshold = math.min(radiusPx / pxPerSec, maxSec);
    final candidates = <double>[0];
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
  double snapEdge(TimelineClip moving, double want, double pxPerSec) =>
      snapTime(want, pxPerSec, exceptId: moving.id);

  /// 拖曳時的貼齊：只吸到其他素材的頭尾（自己的頭對它們的頭尾、
  /// 自己的尾對它們的頭尾，四種組合）。理由同 [snapTime]
  double snapOffset(TimelineClip moving, double want, double pxPerSec) {
    // 跟 snapTime 同一組手感參數
    final threshold = math.min(16 / pxPerSec, 0.5);
    final len = moving.length;
    // 片頭跟片尾各一個固定錨點：拖到最前面要黏在 0，拖到最後面要跟
    // 現有素材的結尾對齊。只吸別人的頭尾的話，拖到空軌上或整條軸就
    // 這一段時附近沒有候選，手一放就停在離片頭一點點的怪地方
    final candidates = <double>[0];
    var contentEnd = 0.0;
    for (final c in clips) {
      if (c.id == moving.id) continue;
      if (c.end > contentEnd) contentEnd = c.end;
      candidates.addAll([c.offset, c.end, c.offset - len, c.end - len]);
    }
    if (contentEnd > 0) candidates.add(contentEnd - len);
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
