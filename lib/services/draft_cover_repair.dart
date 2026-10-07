import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../models/timeline.dart';
import 'app_media_paths.dart';
import 'draft_store.dart';
import 'file_reader.dart';
import 'native_frames.dart';
import 'photo_export.dart';

/// 封面要從哪一格抽：素材路徑（還沒換成這次安裝的容器路徑）、工作檔、
/// 是不是影片、素材裡的第幾秒、素材比例（抽出來的那格量不到時用）
typedef DraftCoverPick = ({
  String path,
  String? work,
  bool video,
  double at,
  double aspect,
});

/// 沒有封面的影片草稿補一張。
///
/// 十月初那幾版的自動存檔畫好封面又丟掉（見 VideoEditorScreen 的
/// _drainDraftCovers）：那段時間新開的草稿從來沒存到封面，打開過的舊
/// 草稿第一次自動存檔就把原本那張刪掉。修好之後打開再存一次就會有完整
/// 的封面（畫面＋浮水印）；沒再打開的，由個人中心／草稿夾在顯示時補一張
/// ——只抽素材的一格、不畫浮水印，認得出是哪個專案就好。
///
/// 便宜為先：一次一份；整份草稿（含 Logo 的 base64，好幾 MB）在背景
/// isolate 讀檔＋解析，畫面那條執行緒只拿回幾個欄位；影片那一格由原生
/// 抽（背景優先序），照片照長邊 720 解碼（引擎的背景執行緒）。
/// 同一份這次開 App 只試一次：素材不見了的不會每進一次頁面就重試
class DraftCoverRepair {
  DraftCoverRepair._();

  /// 這次開 App 已經試過的（結果只記「有沒有封面」，不留圖在記憶體裡）
  static final Map<String, Future<bool>> _jobs = {};

  /// 補好（或這中間編輯器已經存了一張）回那張封面的 base64；補不了回 null
  static Future<String?> fill(String id) async {
    if (kIsWeb) return null; // web 的素材是 blob 連結，重新整理就失效
    final ok = await _jobs.putIfAbsent(id, () => _fill(id));
    return ok ? DraftStore.thumb(id) : null;
  }

  @visibleForTesting
  static void resetForTest() => _jobs.clear();

  static Future<bool> _fill(String id) async {
    try {
      if (await DraftStore.hasThumbFile(id)) return true;
      final pick = await _pick(id);
      if (pick == null) return false;
      final cover = await _render(pick);
      if (cover == null) return false;
      if (await DraftStore.fillCover(
        id,
        thumb: base64Encode(cover.$1),
        aspect: cover.$2,
      )) {
        return true;
      }
      // 沒寫進去：多半是這中間編輯器存了真的封面（那張比較好，用它）
      return await DraftStore.hasThumbFile(id);
    } catch (_) {
      return false;
    }
  }

  static Future<DraftCoverPick?> _pick(String id) async {
    final file = await DraftStore.dataFilePath(id);
    final DraftCoverPick? raw;
    if (file != null) {
      raw = await compute(_pickFromFile, file);
    } else {
      // 沒有檔案系統（沒跑 main 的測試）：內容本來就在記憶體裡
      final json = await DraftStore.rawJson(id);
      raw = json == null ? null : pickDraftCover(json);
    }
    if (raw == null) return null;
    // 路徑換成這次安裝的容器（iOS 每次重裝容器路徑都會變，見
    // AppMediaPaths）；背景 isolate 沒有這份設定，回來才換
    final work = raw.work;
    return (
      path: AppMediaPaths.rebase(raw.path),
      work: work == null ? null : AppMediaPaths.rebase(work),
      video: raw.video,
      at: raw.at,
      aspect: raw.aspect,
    );
  }

  static Future<(Uint8List, double)?> _render(DraftCoverPick p) async {
    if (p.video) {
      // 工作檔（1080p SDR 代理）先：原檔多半是 4K HDR，解一格貴得多
      for (final path in [?p.work, p.path]) {
        if (!await fileExists(path)) continue;
        final b = await nativeFrameAt(path, p.at, maxH: 720, background: true);
        if (b != null) return (b, await _aspectOf(b) ?? p.aspect);
      }
      return null;
    }
    final bytes = await readFileBytes(p.path);
    if (bytes == null) return null;
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 720,
      allowUpscaling: false,
    );
    try {
      final image = (await codec.getNextFrame()).image;
      try {
        final enc = await encodePhotoImage(image, jpeg: true, quality: 85);
        return (enc.bytes, image.width / image.height);
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  /// 只讀檔頭量寬高，不整張解碼
  static Future<double?> _aspectOf(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      try {
        final desc = await ui.ImageDescriptor.encoded(buffer);
        try {
          return desc.height > 0 ? desc.width / desc.height : null;
        } finally {
          desc.dispose();
        }
      } finally {
        buffer.dispose();
      }
    } catch (_) {
      return null;
    }
  }
}

/// 背景 isolate 裡跑：讀檔＋解析，只回封面那一層的幾個欄位
Future<DraftCoverPick?> _pickFromFile(String path) async {
  final bytes = await readFileBytes(path);
  if (bytes == null) return null;
  return pickDraftCover(utf8.decode(bytes, allowMalformed: true));
}

/// 封面用哪一層：一開場（跟編輯器的封面同一刻，t≈0.02 秒）看得到的
/// 片段優先，其中影片優先（影片專案的主角；照片多半是疊上去的）、軌道
/// 越上面越優先（多選匯入各自一軌全疊在 0 秒，看得到的是最上面那支）。
/// 一開場什麼都沒有（片頭空一段）就取最早出現的。隱藏的軌道不算
@visibleForTesting
DraftCoverPick? pickDraftCover(String json) {
  try {
    final j = jsonDecode(json);
    if (j is! Map) return null;
    final sources = j['sources'];
    final clips = j['clips'];
    if (sources is! List || clips is! List) return null;
    final hidden = {
      for (final t in (j['hiddenTracks'] as List? ?? const []))
        if (t is int) t,
    };
    const t0 = 0.02;
    TimelineClip? best;
    Map<dynamic, dynamic>? bestSource;
    var bestVideo = false;
    _Rank? bestRank;
    for (final cj in clips) {
      if (cj is! Map) continue;
      final TimelineClip c;
      try {
        c = TimelineClip.fromJson(Map<String, dynamic>.from(cj));
      } catch (_) {
        continue;
      }
      if (c.sourceIndex < 0 || c.sourceIndex >= sources.length) continue;
      if (hidden.contains(c.track)) continue;
      final s = sources[c.sourceIndex];
      if (s is! Map) continue;
      final kind = s['kind'] ?? 0;
      final video = kind == ClipKind.video.index;
      if (!video && kind != ClipKind.image.index) continue;
      final path = s['path'];
      if (path is! String || path.isEmpty) continue;
      // 大的優先。看得到的那幾層都從片頭開始，比的是影片與軌道；
      // 都看不到時先比誰先出現（offset 取負號＝越早越大）
      final visible = c.covers(t0);
      final _Rank rank = (
        visible ? 1 : 0,
        visible ? 0.0 : -c.offset,
        video ? 1 : 0,
        c.track,
      );
      if (bestRank == null || _greater(rank, bestRank)) {
        best = c;
        bestSource = s;
        bestVideo = video;
        bestRank = rank;
      }
    }
    final c = best;
    final s = bestSource;
    if (c == null || s == null) return null;
    final w = s['w'] is num ? (s['w'] as num).toDouble() : 0.0;
    final h = s['h'] is num ? (s['h'] as num).toDouble() : 0.0;
    final work = s['workPath'];
    return (
      path: s['path'] as String,
      work: work is String && work.isNotEmpty ? work : null,
      video: bestVideo,
      at: math.max(0.0, c.sourceTimeAt(math.max(c.offset, t0))),
      aspect: w > 0 && h > 0 ? w / h : 16 / 9,
    );
  } catch (_) {
    return null;
  }
}

/// （片頭看得到、片頭看不到時多早出現、是不是影片、第幾軌），大的優先
typedef _Rank = (int, double, int, int);

bool _greater(_Rank a, _Rank b) {
  if (a.$1 != b.$1) return a.$1 > b.$1;
  if (a.$2 != b.$2) return a.$2 > b.$2;
  if (a.$3 != b.$3) return a.$3 > b.$3;
  return a.$4 > b.$4;
}
