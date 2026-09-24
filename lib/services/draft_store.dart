import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'blob_store.dart';
import 'diagnostics.dart';
import 'work_files.dart';

/// 影片專案草稿：可以同時存好幾個，每個有自己的名字。
///
/// 以前只有一個固定的鍵（`project_draft_v1`），第二次開新專案就把上一個
/// 蓋掉——剪到一半想先做別的，回來東西就沒了。
///
/// 存法：一個索引鍵記「有哪些草稿、叫什麼名字、什麼時候存的、封面」，
/// 每個草稿的內容各自一個鍵。分開存是因為內容整包含縮圖與 Logo 的
/// base64，動輒好幾百 KB——每次列清單都要把全部解碼一次的話，
/// 首頁進場就會卡住。
///
/// 內容與封面存成檔案（[BlobStore]），只有索引留在 SharedPreferences：
/// iOS 開 App 就把整個設定檔讀進記憶體，上百份草稿各帶一份 Logo 的
/// base64，實機剛開 App 就吃掉 1.4GB（見 BlobStore 的說明）
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

  /// 這份草稿用到的檔案清單的鍵前綴（素材原檔、工作檔、HDR 代理、倒轉
  /// 的來源）。很小：草稿夾算容量、刪草稿時判斷哪些轉檔暫存沒人用了，
  /// 都只讀這個——不用為了這件事把整份內容（含 Logo）讀進來
  static const _refsPrefix = 'project_refs_';

  static String _dataKey(String id) => '$_dataPrefix$id';
  static String _thumbKey(String id) => '$_thumbPrefix$id';
  static String _refsKey(String id) => '$_refsPrefix$id';

  /// 內容、封面、檔案清單三筆的鍵（容量統計用）
  static List<String> blobKeys(String id) => [
    _dataKey(id),
    _thumbKey(id),
    _refsKey(id),
  ];

  /// 這份草稿的內容檔在哪（沒有檔案系統＝null）：舊草稿沒有檔案清單時，
  /// 容量統計交給背景 isolate 直接讀這個檔，不經過畫面那條執行緒
  static Future<String?> dataFilePath(String id) async =>
      (await BlobStore.fileOf(_dataKey(id)))?.path;

  /// 這份草稿用到的檔案（見 [_refsPrefix]）。這一版之前存的草稿沒有，回 null
  static Future<Set<String>?> refs(String id) async {
    final s = await BlobStore.read(_refsKey(id));
    if (s == null) return null;
    try {
      return {for (final e in jsonDecode(s) as List) '$e'};
    } catch (_) {
      return null;
    }
  }

  /// 舊草稿的檔案清單由草稿夾算出來補寫。跟存檔排同一列，而且編輯器
  /// 已經寫過（比較新）就不蓋
  static Future<void> fillRefs(String id, Set<String> refs) => _serial(() async {
    if (await BlobStore.exists(_refsKey(id))) return;
    if (!await BlobStore.exists(_dataKey(id))) return; // 草稿已經被刪了
    await BlobStore.write(_refsKey(id), _encodeRefs(refs));
  });

  static String _encodeRefs(Set<String> refs) => jsonEncode(refs.toList()..sort());

  /// 上一次寫進去的檔案清單（草稿 id, 編碼後的字串）：沒變就不重寫
  static (String, String)? _refsWritten;

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
  static Future<String?> thumb(String id) => BlobStore.read(_thumbKey(id));

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
    for (final k in await BlobStore.keysWithPrefix(_dataPrefix)) {
      final id = k.substring(_dataPrefix.length);
      var savedAt = DateTime.now();
      var clips = 0;
      try {
        final j = Map<String, dynamic>.from(
          jsonDecode(await BlobStore.read(k) ?? '') as Map,
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
          hasThumb: await BlobStore.exists(_thumbKey(id)),
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
    final s = await BlobStore.read(_dataKey(id));
    if (s == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return null;
    }
  }

  /// 上一次真的寫進去的封面（草稿 id, 字串本身）。編輯器沒換封面時每次
  /// 存檔傳進來的是同一個字串物件，不用再把一張封面重寫一次——以前每個
  /// 編輯動作的自動存檔都連封面一起重寫
  static (String, String)? _thumbWritten;

  /// 存一份草稿。[content] 是編碼好的 JSON 字串，或還沒編碼的 Map——
  /// Map 的話編碼跟寫檔一起在背景 isolate 做（[BlobStore.writeJson]；
  /// 這是每個編輯動作都會走到的路，整包含 Logo 的 base64）。
  /// 回傳有沒有真的寫進去。SharedPreferences 寫入失敗（空間滿、
  /// prefs 損毀）以前被吞掉，使用者整場都以為有自動存。
  /// 內容、封面及索引都成功寫入才回 true；存檔不順手清理其他草稿。
  static Future<bool> save(
    String id,
    Object content, {
    String? thumb,
    double? thumbAspect,
    int clipCount = 0,
    double duration = 0,
    Set<String>? refs,
  }) async {
    var json = content;
    if (json is! String && !BlobStore.usesFiles) {
      // 走 prefs（web、widget 測試）：跟以前一樣在排隊之前先編碼好
      try {
        json = kIsWeb ? jsonEncode(json) : await compute(jsonEncode, json);
      } catch (_) {
        json = jsonEncode(json);
      }
    }
    try {
      return await _serial(() async {
        var ok = false;
        try {
          ok = await _saveInner(
            id,
            json,
            thumb: thumb,
            thumbAspect: thumbAspect,
            clipCount: clipCount,
            duration: duration,
            refs: refs,
          );
        } finally {
          if (!ok) {
            // prefs 先更新記憶體才寫平台。失敗後在這次排程內重讀，
            // 避免下個儲存或清理讀到未落地的內容／索引。
            try {
              await (await SharedPreferences.getInstance()).reload();
            } catch (_) {}
          }
        }
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
    Object json, {
    String? thumb,
    double? thumbAspect,
    int clipCount = 0,
    double duration = 0,
    Set<String>? refs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await _migrate(prefs);
    final wrote = json is String
        ? await BlobStore.write(_dataKey(id), json)
        : await BlobStore.writeJson(_dataKey(id), json);
    if (!wrote) return false;
    if (thumb != null) {
      final last = _thumbWritten;
      final same = last != null && last.$1 == id && identical(last.$2, thumb);
      // 還是要確認檔案在：被別的路徑刪掉的話照樣補寫
      if (!same || !await BlobStore.exists(_thumbKey(id))) {
        if (!await BlobStore.write(_thumbKey(id), thumb)) return false;
        _thumbWritten = (id, thumb);
      }
    } else {
      if (!await BlobStore.delete(_thumbKey(id))) return false;
      if (_thumbWritten?.$1 == id) _thumbWritten = null;
    }
    if (refs != null) {
      final text = _encodeRefs(refs);
      final last = _refsWritten;
      final same = last != null && last.$1 == id && last.$2 == text;
      // 寫不進去不算存檔失敗：只影響容量統計與刪除時的連帶清理（清不到
      // 就留著），下一次存檔再補
      if (!same || !await BlobStore.exists(_refsKey(id))) {
        if (await BlobStore.write(_refsKey(id), text)) _refsWritten = (id, text);
      }
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
    return _writeIndex(prefs, metas);
  }

  static Future<void> remove(String id) => _serial(() => _removeInner(id));

  /// 一次刪好幾份（草稿夾的多選刪除）：索引只重寫一次、連帶清理只算
  /// 一次——一份一份刪的話，每刪一份都要把剩下每份的檔案清單讀一遍
  static Future<void> removeMany(Set<String> ids) => _serial(() async {
    if (ids.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    if (ids.contains(_thumbWritten?.$1)) _thumbWritten = null;
    if (ids.contains(_refsWritten?.$1)) _refsWritten = null;
    final gone = <Set<String>>[];
    var done = 0;
    for (final id in ids) {
      final r = await refs(id);
      if (r != null) gone.add(r);
      await BlobStore.delete(_dataKey(id));
      await BlobStore.delete(_thumbKey(id));
      await BlobStore.delete(_refsKey(id));
      if (++done % 10 == 0) await Future<void>.delayed(Duration.zero);
    }
    final rest = await list()
      ..removeWhere((m) => ids.contains(m.id));
    await _writeIndex(prefs, rest);
    await _releaseFilesOf(gone, rest);
  });

  /// 把舊版的封面（720p PNG，一張 1.2MB）換成同一張的 JPEG。只有檔案裡
  /// 還是 [oldB64] 那一張才換：這中間編輯器存了新封面的話就不動它
  static Future<bool> replaceThumbIfSame(
    String id,
    String oldB64,
    String newB64,
  ) => _serial(() async {
    final now = await BlobStore.read(_thumbKey(id));
    if (now == null || now != oldB64) return false;
    if (!await BlobStore.write(_thumbKey(id), newB64)) return false;
    if (_thumbWritten?.$1 == id) _thumbWritten = null;
    return true;
  });

  static Future<void> _removeInner(String id) async {
    final prefs = await SharedPreferences.getInstance();
    if (_thumbWritten?.$1 == id) _thumbWritten = null;
    if (_refsWritten?.$1 == id) _refsWritten = null;
    final gone = await refs(id);
    await BlobStore.delete(_dataKey(id));
    await BlobStore.delete(_thumbKey(id));
    await BlobStore.delete(_refsKey(id));
    final metas = await list()
      ..removeWhere((m) => m.id == id);
    await _writeIndex(prefs, metas);
    await _releaseFilesOf([?gone], metas);
  }

  /// 刪掉的草稿用到、而且剩下的草稿都沒在用的轉檔暫存（工作檔、HDR
  /// 代理、倒轉檔、救回的素材）一起清——以前刪草稿只刪它自己那兩個檔，
  /// 幾百 MB 的代理留著，刪了也不會多出空間。
  /// 剩下的草稿有任何一份還沒有檔案清單（這一版之前存的、還沒被草稿夾
  /// 算過）就整個不清：寧可多留。草稿夾算完會把它們列成「沒有草稿在
  /// 用」，讓使用者自己按清掉
  static Future<void> _releaseFilesOf(
    List<Set<String>> gone,
    List<DraftMeta> rest,
  ) async {
    // 沒有檔案系統（web、沒跑 main 的 widget 測試）就沒有轉檔暫存；也不能
    // 去問 path_provider——假時間裡沒掛假通道的平台呼叫永遠等不到回覆，
    // 整條存檔佇列會跟著卡住
    if (kIsWeb || gone.isEmpty || !BlobStore.usesFiles) return;
    try {
      final remaining = <String>{};
      for (final m in rest) {
        final r = await refs(m.id);
        if (r == null) return;
        remaining.addAll(r);
      }
      await WorkFiles.releaseRefs({
        for (final g in gone) ...g,
      }, referenced: remaining.contains);
    } catch (_) {}
  }

  /// 超過上限就把最舊的草稿刪掉，回傳刪掉的 id（新到舊排序無關，
  /// 就是被刪的那幾個）。
  ///
  /// 連帶清「只有它們在用」的 App 自有檔案：工作檔、HDR 代理、倒轉檔、
  /// 救回來的素材（見 [_releaseFilesOf]；只讀每份草稿的檔案清單）。別份
  /// 草稿還在用的一律不碰；使用者相簿裡的原檔本來就不在清理範圍。
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

      // 不讀每一份草稿的內容去算「哪些檔案沒人用了」：一份草稿好幾百 KB
      // （內嵌封面與圖片），實機 113 份要刪 83 份時，那一輪比對等於把上百 MB
      // 讀進記憶體，App 直接被系統殺掉（回報：點清理就當機）。改讀每份草稿
      // 存檔時另外寫的檔案清單（project_refs_，幾百位元組）
      var done = 0;
      if (victimIds.contains(_thumbWritten?.$1)) _thumbWritten = null;
      if (victimIds.contains(_refsWritten?.$1)) _refsWritten = null;
      final gone = <Set<String>>[];
      for (final v in victims) {
        final r = await refs(v.id);
        if (r != null) gone.add(r);
        await BlobStore.delete(_dataKey(v.id));
        await BlobStore.delete(_thumbKey(v.id));
        await BlobStore.delete(_refsKey(v.id));
        // 每 10 份讓出一次主執行緒：一次刪上百份也不會整個畫面凍住
        if (++done % 10 == 0) await Future<void>.delayed(Duration.zero);
      }
      final rest = [
        for (final m in metas)
          if (!victimIds.contains(m.id)) m,
      ];
      await _writeIndex(prefs, rest);
      // 連帶清只有它們在用的轉檔暫存：只讀每份草稿那個很小的檔案清單，
      // 不讀內容（見 _releaseFilesOf）
      await _releaseFilesOf(gone, rest);
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

  static Future<bool> _writeIndex(
    SharedPreferences prefs,
    List<DraftMeta> metas,
  ) async {
    metas.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return prefs.setString(
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
    await BlobStore.write(_dataKey(id), old);
    final oldThumb = j['thumb'] as String?;
    if (oldThumb != null) await BlobStore.write(_thumbKey(id), oldThumb);
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
