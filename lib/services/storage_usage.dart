import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'blob_store.dart';
import 'draft_assets.dart';
import 'draft_store.dart';
import 'work_files.dart';

/// 照片／批次／拼圖／GIF 各一份的草稿存在這幾個鍵（見 BlobStore.ownedKeys）
const _singleDraftKeys = [
  'photo_draft_v1',
  'batch_draft_v1',
  'collage_draft_v1',
  'gif_draft_v1',
];

/// 草稿夾的容量總表
class StorageReport {
  StorageReport({
    required this.own,
    required this.filesOf,
    required this.sizes,
    required this.draftBytes,
    required this.otherDrafts,
    required this.filesInUse,
    required this.filesUnused,
    required this.pending,
  });

  static final empty = StorageReport(
    own: {},
    filesOf: {},
    sizes: {},
    draftBytes: 0,
    otherDrafts: 0,
    filesInUse: 0,
    filesUnused: 0,
    pending: 0,
  );

  /// 每份影片草稿本身（內容、封面、檔案清單）佔多少
  final Map<String, int> own;

  /// 每份影片草稿用到的轉檔暫存（工作檔、HDR 代理、倒轉檔、救回的素材）
  final Map<String, Set<String>> filesOf;

  /// 轉檔暫存每個檔多大
  final Map<String, int> sizes;

  /// 所有影片草稿本身
  final int draftBytes;

  /// 照片／批次／拼圖／GIF 草稿（內容加留下的素材複本）
  final int otherDrafts;

  /// 有草稿在用的轉檔暫存（去重，共用的只算一次）
  final int filesInUse;

  /// 轉檔暫存裡沒有任何草稿在用的
  final int filesUnused;

  /// 還算不出用了哪些檔案的草稿份數。大於 0 時 [filesUnused] 不可信，
  /// 也不給清（說不定就是那幾份在用）
  final int pending;

  int get total => draftBytes + otherDrafts + filesInUse + filesUnused;

  /// 能不能按「清掉沒在用的暫存」
  bool get canClearUnused => pending == 0 && filesUnused > 0;

  /// 每個轉檔暫存有幾份草稿在用（第一次問才算）
  Map<String, int>? _users;
  Map<String, int> get _userCount => _users ??= () {
    final m = <String, int>{};
    for (final fs in filesOf.values) {
      for (final f in fs) {
        m[f] = (m[f] ?? 0) + 1;
      }
    }
    return m;
  }();

  /// 把 [ids] 這幾份一起刪掉實際能省下多少：它們自己，加上只有它們在用
  /// 的轉檔暫存（別份草稿也在用的不會被刪，就不算）
  int freeableFor(Set<String> ids) {
    var n = 0;
    final inSet = <String, int>{};
    for (final id in ids) {
      n += own[id] ?? 0;
      for (final f in filesOf[id] ?? const <String>{}) {
        inSet[f] = (inSet[f] ?? 0) + 1;
      }
    }
    final users = _userCount;
    for (final e in inSet.entries) {
      if ((users[e.key] ?? 0) <= e.value) n += sizes[e.key] ?? 0;
    }
    return n;
  }
}

/// 草稿夾的「佔多少空間」：讓使用者自己判斷要不要刪。
///
/// 只讀小東西：每份草稿的檔案大小（stat）、存檔時另外寫的檔案清單
/// （project_refs_，見 DraftStore）、工作檔索引。不讀草稿內容——
/// 上百份草稿的完整 JSON 一起讀進來曾經讓 App 被系統殺掉。
/// 這一版之前存的草稿沒有檔案清單：交給背景 isolate 讀它的內容檔、
/// 只把路徑清單帶回來，一份一份來，算完補寫回去，下次就不用再算
class StorageUsage {
  StorageUsage._();

  /// 算一次。[onProgress]：舊草稿補算檔案清單時回報（第幾份／共幾份）
  static Future<StorageReport> scan({
    void Function(int done, int total)? onProgress,
  }) async {
    final metas = await DraftStore.list();
    final own = <String, int>{};
    final refsOf = <String, Set<String>>{};
    final missing = <String>[];
    for (final m in metas) {
      var bytes = 0;
      for (final k in DraftStore.blobKeys(m.id)) {
        bytes += await BlobStore.sizeOf(k);
      }
      own[m.id] = bytes;
      final r = await DraftStore.refs(m.id);
      if (r == null) {
        missing.add(m.id);
      } else {
        refsOf[m.id] = r;
      }
    }
    var pending = 0;
    for (var i = 0; i < missing.length; i++) {
      onProgress?.call(i, missing.length);
      final id = missing[i];
      final r = await _extractRefs(id);
      if (r == null) {
        pending++;
        continue;
      }
      refsOf[id] = r;
      await DraftStore.fillRefs(id, r);
    }
    if (missing.isNotEmpty) onProgress?.call(missing.length, missing.length);

    // 沒有檔案系統（web、沒跑 main 的 widget 測試）就沒有轉檔暫存可算——
    // 也不能去問 path_provider：假時間裡沒掛假通道的平台呼叫永遠等不到回覆
    final files = BlobStore.usesFiles;
    final inv = files
        ? await WorkFiles.inventory()
        : (sizes: <String, int>{}, bySource: <String, Set<String>>{});
    final sizes = inv.sizes;
    // 每份草稿用到的 App 自有檔案：直接指著的（救回的素材、倒轉檔、
    // 記下的工作檔路徑），加上它的原檔在索引裡的每一支工作檔
    final filesOf = <String, Set<String>>{};
    final used = <String>{};
    for (final e in refsOf.entries) {
      final files = <String>{
        for (final r in e.value) ...[
          if (sizes.containsKey(r)) r,
          for (final w in inv.bySource[r] ?? const <String>{})
            if (sizes.containsKey(w)) w,
        ],
      };
      filesOf[e.key] = files;
      used.addAll(files);
    }
    var draftBytes = 0;
    for (final n in own.values) {
      draftBytes += n;
    }
    var inUse = 0;
    var unused = 0;
    for (final e in sizes.entries) {
      // 正在寫的檔還沒進任何草稿：算在用，不給清
      if (used.contains(e.key) || WorkFiles.isInFlight(e.key)) {
        inUse += e.value;
      } else {
        unused += e.value;
      }
    }
    var other = files ? await DraftAssets.usageBytes() : 0;
    for (final k in _singleDraftKeys) {
      other += await BlobStore.sizeOf(k);
    }
    return StorageReport(
      own: own,
      filesOf: filesOf,
      sizes: sizes,
      draftBytes: draftBytes,
      otherDrafts: other,
      filesInUse: inUse,
      filesUnused: unused,
      pending: pending,
    );
  }

  /// 清掉沒有任何草稿在用的轉檔暫存，回傳省下的位元組。
  /// 每一份草稿的檔案清單都要拿得到才清，任何一份拿不到就什麼都不動
  static Future<int> clearUnused() async {
    if (!BlobStore.usesFiles) return 0;
    final metas = await DraftStore.list();
    final used = <String>{};
    for (final m in metas) {
      final r = await DraftStore.refs(m.id);
      if (r == null) return 0;
      used.addAll(r);
    }
    return WorkFiles.releaseUnreferenced(referenced: used.contains);
  }

  /// 舊草稿的檔案清單：背景 isolate 讀內容檔、只帶路徑回來。
  /// 讀不到內容（檔案壞了）回 null
  static Future<Set<String>?> _extractRefs(String id) async {
    if (kIsWeb) return <String>{};
    final path = await DraftStore.dataFilePath(id);
    if (path == null) return null;
    try {
      final list = await compute(extractDraftRefs, path);
      return list?.toSet();
    } catch (_) {
      return null;
    }
  }
}

/// 背景 isolate 裡跑：讀一份草稿內容檔，把它用到的路徑列出來
/// （素材原檔、工作檔、HDR 代理、倒轉的來源）。檔案不在回空清單，
/// 解不開回 null
@visibleForTesting
List<String>? extractDraftRefs(String path) {
  final f = File(path);
  if (!f.existsSync()) return const [];
  try {
    final j = jsonDecode(f.readAsStringSync());
    if (j is! Map) return null;
    return draftRefsOf(j);
  } catch (_) {
    return null;
  }
}

/// 一份草稿內容裡用到的路徑（跟編輯器存檔時寫的檔案清單同一套欄位，
/// 見 VideoEditorScreen._draftFileRefs）
List<String> draftRefsOf(Map<dynamic, dynamic> j) {
  final out = <String>{};
  for (final s in (j['sources'] as List? ?? const [])) {
    if (s is! Map) continue;
    for (final k in const ['path', 'workPath', 'workHdr', 'revOf']) {
      final v = s[k];
      if (v is String && v.isNotEmpty) out.add(v);
    }
  }
  return out.toList()..sort();
}

/// 容量給人看的寫法：1.2 GB／350 MB／不到 1 MB
String formatBytes(int bytes) {
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  if (bytes >= gb) {
    return '${(bytes / gb).toStringAsFixed(bytes >= 10 * gb ? 0 : 1)} GB';
  }
  if (bytes >= mb) return '${(bytes / mb).round()} MB';
  if (bytes <= 0) return '0 MB';
  return '不到 1 MB';
}
