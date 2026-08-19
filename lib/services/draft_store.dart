import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 影片專案草稿：可以同時存好幾個，每個有自己的名字。
///
/// 以前只有一個固定的鍵（`project_draft_v1`），第二次開新專案就把上一個
/// 蓋掉——剪到一半想先做別的，回來東西就沒了。
///
/// 存法：一個索引鍵記「有哪些草稿、叫什麼名字、什麼時候存的、封面」，
/// 每個草稿的內容各自一個鍵。分開存是因為內容整包含縮圖與 Logo 的
/// base64，動輒好幾百 KB——每次列清單都要把全部解碼一次的話，
/// 首頁進場就會卡住
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

  static String _dataKey(String id) => '$_dataPrefix$id';
  static String _thumbKey(String id) => '$_thumbPrefix$id';

  /// 讀某一份草稿的封面（base64 PNG/JPEG）
  static Future<String?> thumb(String id) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_thumbKey(id));
  }

  /// 讀清單（新到舊）。順便把舊版單一草稿搬進來
  static Future<List<DraftMeta>> list() async {
    final prefs = await SharedPreferences.getInstance();
    await _migrate(prefs);
    final raw = prefs.getString(_indexKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      final out = [
        for (final e in list)
          DraftMeta.fromJson(Map<String, dynamic>.from(e as Map)),
      ]..sort((a, b) => b.savedAt.compareTo(a.savedAt));
      return out;
    } catch (_) {
      return [];
    }
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
  static Future<void> save(
    String id,
    String json, {
    required String name,
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
    metas.removeWhere((m) => m.id == id);
    metas.add(
      DraftMeta(
        id: id,
        name: name,
        savedAt: DateTime.now(),
        hasThumb: thumb != null,
        thumbAspect: thumbAspect,
        clipCount: clipCount,
        duration: duration,
      ),
    );
    await _writeIndex(prefs, metas);
  }

  static Future<void> rename(String id, String name) async {
    final prefs = await SharedPreferences.getInstance();
    final metas = await list();
    for (final m in metas) {
      if (m.id == id) m.name = name;
    }
    await _writeIndex(prefs, metas);
  }

  static Future<void> remove(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dataKey(id));
    await prefs.remove(_thumbKey(id));
    final metas = await list()
      ..removeWhere((m) => m.id == id);
    await _writeIndex(prefs, metas);
  }

  /// 產生一個新的草稿 id
  static String newId() =>
      'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// 沒取名字時用的預設名：「專案 1」「專案 2」…（避開已用過的號碼）
  static Future<String> defaultName() async {
    final used = <int>{};
    for (final m in await list()) {
      final n = RegExp(r'^專案 (\d+)$').firstMatch(m.name);
      if (n != null) used.add(int.parse(n.group(1)!));
    }
    var i = 1;
    while (used.contains(i)) {
      i++;
    }
    return '專案 $i';
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
      name: '未命名專案',
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
  String name;
  final DateTime savedAt;

  /// 有沒有封面（內容另外存，見 DraftStore.thumb）
  final bool hasThumb;
  final double? thumbAspect;
  final int clipCount;
  final double duration;

  DraftMeta({
    required this.id,
    required this.name,
    required this.savedAt,
    this.hasThumb = false,
    this.thumbAspect,
    this.clipCount = 0,
    this.duration = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'savedAt': savedAt.toIso8601String(),
    if (hasThumb) 'hasThumb': true,
    if (thumbAspect != null) 'thumbAspect': thumbAspect,
    'clips': clipCount,
    'dur': duration,
  };

  factory DraftMeta.fromJson(Map<String, dynamic> j) => DraftMeta(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '未命名專案',
    savedAt: DateTime.tryParse(j['savedAt'] as String? ?? '') ?? DateTime(2000),
    hasThumb: j['hasThumb'] == true,
    thumbAspect: (j['thumbAspect'] as num?)?.toDouble(),
    clipCount: ((j['clips'] ?? 0) as num).toInt(),
    duration: ((j['dur'] ?? 0) as num).toDouble(),
  );
}
