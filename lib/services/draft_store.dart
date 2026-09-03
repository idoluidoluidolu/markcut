import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostics.dart';
import 'work_files.dart';

/// 清掉草稿時連帶清 App 自有檔案的那一手（見 [WorkFiles.releaseFiles]）。
/// [referenced]：這條路徑（或工作檔的原始來源）還有沒有活著的草稿在用
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
/// 只會越來越多：有一個固定的上限（[maxDrafts]），超過之後由使用者
/// 在草稿夾按「清理」，從最舊的開始刪，見 [prune]
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

  /// 舊版那個「保留份數」的設定鍵。上限不給調了（使用者指定：那顆
  /// 按鈕刪掉，一律預設 30），這個鍵只剩下被刪的份——舊裝置上調過
  /// 的值留著不管，會讓人以為它還有效（見 [_migrate]）
  static const _staleMaxKey = 'drafts_max_v1';

  /// 最多留幾份草稿。固定值，沒有設定可以調：草稿一份好幾百 KB 都塞在
  /// SharedPreferences，放任不管會把整個 prefs 拖垮，而三十份對誰都夠。
  /// 超過也不會自己刪，要使用者在草稿夾按「清理」（見 [prune]）
  static const int maxDrafts = 30;

  static String _dataKey(String id) => '$_dataPrefix$id';
  static String _thumbKey(String id) => '$_thumbPrefix$id';

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
  /// （[holdOpen]）也一律不碰。**只有使用者在草稿夾按「清理」才會跑**——
  /// 開機、存檔、進草稿夾都不跑（掃描成本高，見上面的說明）
  static Future<List<String>> prune({Set<String> keep = const {}}) =>
      _serial(() => _pruneInner(keep: keep));

  static Future<List<String>> _pruneInner({Set<String> keep = const {}}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const cap = maxDrafts;
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

      // 只刪草稿紀錄本身。不再讀每一份草稿的內容去算「哪些檔案沒人用了」：
      // 一份草稿好幾百 KB（內嵌封面與圖片），實機 113 份要刪 83 份時，那一輪
      // 比對等於把上百 MB 讀進記憶體，App 直接被系統殺掉（回報：點清理就當機）。
      // 工作檔／HDR 代理交給 WorkFiles.sweep 用自己的規則清（只看索引與檔案
      // 在不在，成本跟草稿份數無關）
      var done = 0;
      for (final v in victims) {
        await prefs.remove(_dataKey(v.id));
        await prefs.remove(_thumbKey(v.id));
        // 每 10 份讓出一次主執行緒：一次刪上百份也不會整個畫面凍住
        if (++done % 10 == 0) await Future<void>.delayed(Duration.zero);
      }
      final rest = [
        for (final m in metas)
          if (!victimIds.contains(m.id)) m,
      ];
      await _writeIndex(prefs, rest);
      Diag.note('草稿清理：刪掉最舊的 ${victims.length} 份（保留 $cap 份）');
      return [for (final v in victims) v.id];
    } catch (_) {
      return const [];
    }
  }

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
    // 順手把舊版「保留份數」存下來的值刪掉：上限改成固定 30 之後
    // 沒人會再讀它，留在 prefs 裡只會讓人以為自己調的還算數
    if (prefs.containsKey(_staleMaxKey)) await prefs.remove(_staleMaxKey);
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
