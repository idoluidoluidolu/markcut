import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostics.dart';
import 'work_files.dart';

/// 清掉草稿時連帶清 App 自有檔案的那一手（見 [WorkFiles.releaseFiles]）。
/// [referenced]：這條路徑（或工作檔的原始來源）還有沒有活著的草稿在用
typedef DraftFileReleaser =
    Future<int> Function(
      Set<String> paths, {
      required bool Function(String path) referenced,
    });

/// 影片專案草稿：可以同時存好幾個，每個有自己的名字。
///
/// 以前只有一個固定的鍵（`project_draft_v1`），第二次開新專案就把上一個
/// 蓋掉——剪到一半想先做別的，回來東西就沒了。
///
/// 存法：一個索引鍵記「有哪些草稿、叫什麼名字、什麼時候存的、封面」，
/// 每個草稿的內容各自一個鍵。分開存是因為內容整包含縮圖與 Logo 的
/// base64，動輒好幾百 KB——每次列清單都要把全部解碼一次的話，
/// 首頁進場就會卡住
///
/// 每個影片專案進編輯器就自動存成草稿（不用選「保留」），所以數量
/// 只會越來越多：有一個上限（[maxDrafts]，預設 [defaultMax]），
/// 超過就從最舊的開始自動刪，見 [prune]
class DraftStore {
  /// 索引：[DraftMeta] 的清單
  static const _indexKey = 'projects_index_v1';

  /// 單一草稿內容的鍵前綴
  static const _dataPrefix = 'project_data_';

  /// 封面縮圖的鍵前綴。
  ///
  /// 不放進索引：封面是 base64 的 720p 影格，一張就上百 KB，
  /// 放進去的話每次列清單都要把所有草稿的封面一起解析一遍——
  /// 十份草稿就是一個 1MB 的字串，開個人中心會卡住
  static const _thumbPrefix = 'project_thumb_';

  /// 舊版那個唯一的草稿鍵（搬完就刪）
  static const _legacyKey = 'project_draft_v1';

  /// 草稿數量上限的設定鍵（草稿夾右上角可以調）
  static const _maxKey = 'drafts_max_v1';

  /// 預設最多留幾份。超過就從最舊的開始自動刪（見 [prune]）
  static const defaultMax = 30;

  /// 上限可以調的範圍。0 或負數沒有「不限」的意思——草稿一份好幾百 KB
  /// 都塞在 SharedPreferences，放任不管會把整個 prefs 拖垮
  static const minMax = 1;
  static const maxMax = 500;

  /// 草稿夾的設定給人選的那幾個
  static const maxChoices = [10, 20, 30, 50, 100];

  static String _dataKey(String id) => '$_dataPrefix$id';
  static String _thumbKey(String id) => '$_thumbPrefix$id';

  /// 最多留幾份草稿（沒設過就是 [defaultMax]）。
  /// 不快取：prefs 本身就在記憶體裡，讀一次是一次 map 查找
  static Future<int> maxDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    final n = prefs.getInt(_maxKey);
    return n == null ? defaultMax : n.clamp(minMax, maxMax);
  }

  /// 改上限。只存數字，不順手清——要清的話呼叫端自己跑 [prune]
  ///（草稿夾會先告訴使用者哪幾份要被刪，確認了才清）
  static Future<void> setMaxDrafts(int n) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_maxKey, n.clamp(minMax, maxMax));
  }

  /// 正在編輯中的草稿：上限清理絕不能碰。
  /// 編輯器一存草稿／一載入草稿就登記，離開專案時解除
  static final Set<String> _open = {};

  static void holdOpen(String id) => _open.add(id);
  static void releaseOpen(String id) => _open.remove(id);

  /// 所有會改動草稿的操作（存、刪、清理）排成一列輪流做。
  /// 清理跟存檔交錯的話，正在寫的那份可能被當成最舊的刪到一半：
  /// 內容剛寫進去、索引還沒更新，清理拿舊索引重寫就把它抹掉了
  static Future<void> _queue = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() body) {
    final done = Completer<void>();
    final prev = _queue;
    _queue = done.future;
    return prev.then((_) => body()).whenComplete(done.complete);
  }

  /// 清掉草稿時連帶清檔案的那一手。測試換成假的，看清理算出哪些檔
  static DraftFileReleaser fileReleaser = defaultFileReleaser;

  static Future<int> defaultFileReleaser(
    Set<String> paths, {
    required bool Function(String path) referenced,
  }) => WorkFiles.releaseFiles(paths, referenced: referenced);

  /// 讀某一份草稿的封面（base64 PNG/JPEG）
  static Future<String?> thumb(String id) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_thumbKey(id));
  }

  /// 讀清單（新到舊）。順便把舊版單一草稿搬進來。
  ///
  /// 索引壞掉「不能」回空清單：save() 會把空清單當事實重寫索引，
  /// 其他草稿的內容都還在卻永遠列不出來——歷史上「草稿全部不見」
  /// 就是這個形狀。壞掉就從內容鍵把索引重建回來
  static Future<List<DraftMeta>> list() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrate(prefs);
    final raw = prefs.getString(_indexKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        final out = [
          for (final e in list)
            DraftMeta.fromJson(Map<String, dynamic>.from(e as Map)),
        ]..sort((a, b) => b.savedAt.compareTo(a.savedAt));
        return out;
      } catch (_) {
        // 原字串留一份備份再重建，之後要追問題還有現場
        await prefs.setString('projects_index_backup', raw);
      }
    }
    return _rebuildIndex(prefs);
  }

  /// 從還活著的內容鍵（project_data_*）把索引重建回來。
  /// 只在索引遺失或解析失敗時走到；沒有任何內容鍵就回空
  static Future<List<DraftMeta>> _rebuildIndex(SharedPreferences prefs) async {
    final metas = <DraftMeta>[];
    for (final k in prefs.getKeys()) {
      if (!k.startsWith(_dataPrefix)) continue;
      final id = k.substring(_dataPrefix.length);
      var savedAt = DateTime.now();
      var clips = 0;
      try {
        final j = Map<String, dynamic>.from(
          jsonDecode(prefs.getString(k) ?? '') as Map,
        );
        savedAt = DateTime.tryParse(j['savedAt'] as String? ?? '') ?? savedAt;
        clips = (j['clips'] as List?)?.length ?? 0;
      } catch (_) {
        // 內容也壞了：仍列出來讓使用者看得到、自己決定刪不刪
      }
      metas.add(
        DraftMeta(
          id: id,
          savedAt: savedAt,
          hasThumb: prefs.getString(_thumbKey(id)) != null,
          clipCount: clips,
        ),
      );
    }
    if (metas.isNotEmpty) await _writeIndex(prefs, metas);
    metas.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return metas;
  }

  /// 最近存的那一個（首頁的「繼續上次」用）
  static Future<DraftMeta?> latest() async {
    final all = await list();
    return all.isEmpty ? null : all.first;
  }

  /// 讀某一份草稿的完整內容
  static Future<Map<String, dynamic>?> load(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_dataKey(id));
    if (s == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return null;
    }
  }

  /// 存一份草稿。[json] 已經是編碼好的字串（編碼在背景執行緒做，
  /// 見 _saveDraftNow——那是每個編輯動作都會走到的路）
  /// 回傳有沒有真的寫進去。SharedPreferences 寫入失敗（空間滿、
  /// prefs 損毀）以前被吞掉，使用者整場都以為有自動存。
  /// 存完順手把超過上限的最舊草稿清掉（這一份跟正在編輯的不碰）
  static Future<bool> save(
    String id,
    String json, {
    String? thumb,
    double? thumbAspect,
    int clipCount = 0,
    double duration = 0,
  }) async {
    try {
      return await _serial(() async {
        final ok = await _saveInner(
          id,
          json,
          thumb: thumb,
          thumbAspect: thumbAspect,
          clipCount: clipCount,
          duration: duration,
        );
        // 存檔「不」順手清理：清理要把每一份草稿的完整 JSON（含縮圖與
        // 圖片）讀進來比對引用，草稿多時是幾十 MB 的掃描。匯入一次會存
        // 好幾次草稿，等於每存一次就掃一遍——實機回報「匯入卡住然後閃退」。
        // 清理集中在進草稿夾時做（見 DraftsScreen），那裡等得起
        return ok;
      });
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _saveInner(
    String id,
    String json, {
    String? thumb,
    double? thumbAspect,
    int clipCount = 0,
    double duration = 0,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrate(prefs);
    await prefs.setString(_dataKey(id), json);
    if (thumb != null) {
      await prefs.setString(_thumbKey(id), thumb);
    } else {
      await prefs.remove(_thumbKey(id));
    }
    final metas = await list();
    // 建立時間：第一次存下來的那一刻，之後每次存都留著同一個。
    // 草稿夾顯示的就是它——沒有名字這回事
    final createdAt = metas
        .firstWhere(
          (m) => m.id == id,
          orElse: () => DraftMeta(id: id, savedAt: DateTime.now()),
        )
        .createdAt;
    metas.removeWhere((m) => m.id == id);
    metas.add(
      DraftMeta(
        id: id,
        createdAt: createdAt,
        savedAt: DateTime.now(),
        hasThumb: thumb != null,
        thumbAspect: thumbAspect,
        clipCount: clipCount,
        duration: duration,
      ),
    );
    await _writeIndex(prefs, metas);
    return true;
  }

  static Future<void> remove(String id) => _serial(() => _removeInner(id));

  static Future<void> _removeInner(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dataKey(id));
    await prefs.remove(_thumbKey(id));
    final metas = await list()
      ..removeWhere((m) => m.id == id);
    await _writeIndex(prefs, metas);
  }

  /// 超過上限就把最舊的草稿刪掉，回傳刪掉的 id（新到舊排序無關，
  /// 就是被刪的那幾個）。
  ///
  /// 連帶清「只有它們在用」的 App 自有檔案：工作檔、HDR 代理、
  /// 救回來的素材（見 [WorkFiles.releaseFiles]）。別份草稿還在用的
  /// 一律不碰；使用者相簿裡的原檔本來就不在清理範圍。
  ///
  /// [keep]：這一輪絕不碰的 id（剛存完的那一份）。正在編輯中的
  /// （[holdOpen]）也一律不碰。只在「進草稿夾」與「調小上限」時跑——
  /// 開機與存檔路徑上都不跑（掃描成本高，見上面的說明）
  static Future<List<String>> prune({Set<String> keep = const {}}) =>
      _serial(() => _pruneInner(keep: keep));

  static Future<List<String>> _pruneInner({
    Set<String> keep = const {},
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cap = await maxDrafts();
      final metas = await list(); // 新到舊
      if (metas.length <= cap) return const [];
      final protected = {...keep, ..._open};
      var excess = metas.length - cap;
      final victims = <DraftMeta>[];
      for (final m in metas.reversed) {
        // 最舊的先走
        if (excess <= 0) break;
        if (protected.contains(m.id)) continue;
        victims.add(m);
        excess--;
      }
      if (victims.isEmpty) return const [];
      final victimIds = {for (final v in victims) v.id};

      // 要刪的草稿引用到哪些檔案——只有這幾份要解碼（一份好幾百 KB，
      // 上限清理一次通常只刪一份）
      final candidates = <String>{};
      for (final v in victims) {
        final raw = prefs.getString(_dataKey(v.id));
        if (raw != null) candidates.addAll(_filesIn(raw));
      }
      // 活下來的草稿不解碼：一條路徑還有沒有人在用，看它編碼後的字串
      // 有沒有出現在別份的原始 JSON 裡就夠了（誤判只會往「不刪」偏）。
      // 也認檔名：iOS 每次更新 App 容器路徑的 UUID 都會換，舊草稿記的
      // 是舊前綴，只比整條路徑會漏
      final survivorsRaw = <String>[];
      for (final m in metas) {
        if (victimIds.contains(m.id)) continue;
        final raw = prefs.getString(_dataKey(m.id));
        if (raw != null) survivorsRaw.add(raw);
      }
      bool referenced(String p) {
        final full = jsonEncode(p);
        final name = p.split(RegExp(r'[\\/]')).last;
        final byName = name.isEmpty ? null : '/$name"';
        return survivorsRaw.any(
          (s) => s.contains(full) || (byName != null && s.contains(byName)),
        );
      }

      final orphans = {
        for (final p in candidates)
          if (!referenced(p)) p,
      };

      // 先刪內容再重寫索引（跟 remove 同一個順序）
      for (final v in victims) {
        await prefs.remove(_dataKey(v.id));
        await prefs.remove(_thumbKey(v.id));
      }
      final rest = [
        for (final m in metas)
          if (!victimIds.contains(m.id)) m,
      ];
      await _writeIndex(prefs, rest);
      Diag.note('草稿超過上限 $cap，清掉最舊的 ${victims.length} 份');
      if (orphans.isNotEmpty) {
        try {
          await fileReleaser(orphans, referenced: referenced);
        } catch (_) {
          // 檔案清不掉只是佔空間，草稿本身已經清好了
        }
      }
      return [for (final v in victims) v.id];
    } catch (_) {
      return const [];
    }
  }

  /// 一份草稿 JSON 裡引用到的檔案路徑：素材原檔、工作檔、HDR 代理、
  /// 倒轉前的來源。解析失敗回空——寧可少清也不能亂清
  static Set<String> _filesIn(String raw) {
    final out = <String>{};
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return out;
      for (final s in (j['sources'] as List? ?? const [])) {
        if (s is! Map) continue;
        for (final k in const ['path', 'workPath', 'workHdr', 'revOf']) {
          final v = s[k];
          if (v is String && v.isNotEmpty) out.add(v);
        }
      }
    } catch (_) {}
    return out;
  }

  /// 同一微秒內連開兩個專案時，光靠時間戳會撞號——補一個序號
  static int _seq = 0;

  /// 產生一個新的草稿 id
  static String newId() {
    final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'p$t${(_seq++).toRadixString(36)}';
  }

  static Future<void> _writeIndex(
    SharedPreferences prefs,
    List<DraftMeta> metas,
  ) async {
    metas.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    await prefs.setString(
      _indexKey,
      jsonEncode([for (final m in metas) m.toJson()]),
    );
  }

  /// 舊版的單一草稿 → 清單裡的第一筆。
  ///
  /// 不用「跑過沒」的旗標把關：搬完就把舊鍵刪掉，之後每次都只是
  /// 一次 getString 落空。旗標反而讓同一個行程裡的第二次搬移失效
  static Future<void> _migrate(SharedPreferences prefs) async {
    final old = prefs.getString(_legacyKey);
    if (old == null) return;
    await prefs.remove(_legacyKey);
    Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(old) as Map);
    } catch (_) {
      return;
    }
    // 空草稿不用搬
    if ((j['clips'] as List?)?.isEmpty ?? true) return;
    final id = newId();
    await prefs.setString(_dataKey(id), old);
    final oldThumb = j['thumb'] as String?;
    if (oldThumb != null) await prefs.setString(_thumbKey(id), oldThumb);
    final meta = DraftMeta(
      id: id,
      savedAt:
          DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime.now(),
      hasThumb: oldThumb != null,
      thumbAspect: (j['thumbAspect'] as num?)?.toDouble(),
      clipCount: (j['clips'] as List?)?.length ?? 0,
    );
    await _writeIndex(prefs, [meta]);
  }
}

/// 草稿清單上的一筆（不含專案內容，只有列表要用的那些）
class DraftMeta {
  final String id;

  /// 這份草稿是什麼時候開始的。草稿夾顯示的就是它
  final DateTime createdAt;

  /// 最後一次存的時間（清單照這個由新到舊排）
  final DateTime savedAt;

  /// 有沒有封面（內容另外存，見 DraftStore.thumb）
  final bool hasThumb;
  final double? thumbAspect;
  final int clipCount;
  final double duration;

  DraftMeta({
    required this.id,
    required this.savedAt,
    DateTime? createdAt,
    this.hasThumb = false,
    this.thumbAspect,
    this.clipCount = 0,
    this.duration = 0,
  }) : createdAt = createdAt ?? savedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'savedAt': savedAt.toIso8601String(),
    if (hasThumb) 'hasThumb': true,
    if (thumbAspect != null) 'thumbAspect': thumbAspect,
    'clips': clipCount,
    'dur': duration,
  };

  factory DraftMeta.fromJson(Map<String, dynamic> j) => DraftMeta(
    id: j['id'] as String? ?? '',
    savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime(2000),
    // 舊資料沒有這個欄位，退回存檔時間
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
    hasThumb: j['hasThumb'] == true,
    thumbAspect: (j['thumbAspect'] as num?)?.toDouble(),
    clipCount: ((j['clips'] ?? 0) as num).toInt(),
    duration: ((j['dur'] ?? 0) as num).toDouble(),
  );
}
