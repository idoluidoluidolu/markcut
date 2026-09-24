import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diagnostics.dart';

/// 大字串（影片草稿內容與封面、浮水印範本、貼圖）存成檔案，不放
/// SharedPreferences。
///
/// iOS 的 NSUserDefaults 開 App 時就把整個設定檔載進記憶體，Flutter 的
/// SharedPreferences 又整包複製一份到 Dart，搬的那一下還同時有好幾份暫存。
/// BUILD 218 實機：剛開 App（Flutter 都還沒起）malloc 就 690MB、之後 Dart
/// 常駐 700MB，開 App 一兩秒衝到 2.9GB——草稿上百份、每份各帶一份 Logo 的
/// base64，範本也各帶一份。CI 模擬器（空的設定檔）同一個時間點只有 3MB。
/// 這個底子吃掉了一半的記憶體上限，多支 4K 匯入就是壓垮它的最後一根稻草。
/// 檔案只有真的打開那一份才讀進來。
///
/// Web 沒有檔案系統、沒有 path_provider 的單元測試：照舊用 SharedPreferences。
///
/// 舊資料：每次存取前把 prefs 裡歸這裡管的鍵搬成檔案（寫成功才從 prefs
/// 刪；寫不進去的留在原地、讀的時候也會回頭找）。搬完之後只剩掃一次鍵名。
///
/// 檔案讀寫是非同步的：真正的磁碟寫入與 fsync 在 I/O 執行緒，大草稿的
/// JSON 編碼整段丟背景 isolate（[writeJson]）——自動存檔每個編輯動作都會
/// 走到，同步寫好幾 MB＋fsync 會直接卡在畫面那條執行緒上。
/// 同一個鍵的讀、寫、刪排成一列（[_serialKey]），先寫後讀一定讀到新的，
/// 刪掉的也不會被還在路上的寫入救回來。
/// widget 測試不跑 main、沒叫 [init]，一律走 prefs，碰不到檔案 I/O
///（假時間裡非同步 I/O 永遠等不到回來）
class BlobStore {
  BlobStore._();

  /// 這些前綴的鍵歸這裡管（影片草稿內容、封面、用到的檔案清單）
  static const ownedPrefixes = [
    'project_data_',
    'project_thumb_',
    'project_refs_',
  ];

  /// 這些鍵歸這裡管：範本與貼圖（prefs 裡是字串清單，檔案裡是 JSON 陣列）、
  /// 照片／批次／拼圖／GIF 各一份的草稿（照片、批次、拼圖都帶著 Logo 的
  /// base64，批次的每張覆寫還各帶一份）
  static const ownedKeys = {
    'wm_presets_v1',
    'stickers_v1',
    'photo_draft_v1',
    'batch_draft_v1',
    'collage_draft_v1',
    'gif_draft_v1',
  };

  static bool owns(String key) =>
      ownedKeys.contains(key) || ownedPrefixes.any(key.startsWith);

  /// 測試用：檔案改寫到這個目錄（真機不會設）
  @visibleForTesting
  static Directory? dirOverride;

  /// 開 App 時（main.dart）問一次檔案目錄。沒叫過 [init]＝用 prefs：
  /// widget 測試不跑 main，也不會碰 path_provider——假時間裡沒掛假通道的
  /// 平台呼叫永遠等不到回覆，整個測試會卡死
  static Future<Directory?>? _init;

  /// 開 App 時叫一次：定下檔案目錄、把舊資料搬出 prefs。其他地方的存取
  /// 都等同一個結果，不會有「先讀到舊位置」的時間差
  static Future<void> init() {
    _init ??= _resolve();
    return migrate();
  }

  static Future<Directory?> _resolve() async {
    if (kIsWeb) return null;
    try {
      return _blobs(await getApplicationSupportDirectory());
    } catch (_) {
      return null;
    }
  }

  static Directory _blobs(Directory base) {
    final dir = Directory('${base.path}${Platform.pathSeparator}blobs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 檔案放哪。null＝用 prefs（web、沒叫過 [init]、拿不到目錄）
  static Future<Directory?> _root() async {
    if (kIsWeb) return null;
    final override = dirOverride;
    if (override != null) {
      try {
        return _blobs(override);
      } catch (_) {
        return null;
      }
    }
    final init = _init;
    return init == null ? null : await init;
  }

  @visibleForTesting
  static void resetForTest() => _init = null;

  static File _file(Directory dir, String key) => File(
    '${dir.path}${Platform.pathSeparator}'
    '${key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_')}.txt',
  );

  /// 這個鍵的檔案在哪（沒有檔案系統＝null）。草稿夾算容量用
  static Future<File?> fileOf(String key) async {
    final dir = await _root();
    return dir == null ? null : _file(dir, key);
  }

  /// 同一個鍵的存取排成一列。暫存檔名固定（鍵名＋.tmp）也是靠這個：
  /// 同一個鍵不會有兩筆寫入同時在寫同一個暫存檔
  static final Map<String, Future<void>> _keyQueue = {};

  static Future<T> _serialKey<T>(String key, Future<T> Function() body) {
    final prev = _keyQueue[key] ?? Future<void>.value();
    final done = Completer<void>();
    final tail = done.future;
    _keyQueue[key] = tail;
    return prev.then((_) => body()).whenComplete(() {
      done.complete();
      if (identical(_keyQueue[key], tail)) _keyQueue.remove(key);
    });
  }

  /// 先寫暫存檔再換名：寫到一半被系統殺掉，原本那份還在。
  /// 同步版只給搬舊資料與背景 isolate 用（都不在畫面那條執行緒上等）
  static bool _writeFileSync(File file, String value) {
    final tmp = File('${file.path}.tmp');
    try {
      tmp.writeAsStringSync(value, flush: true);
      tmp.renameSync(file.path);
      return true;
    } catch (_) {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
      return false;
    }
  }

  static Future<bool> _writeFile(File file, String value) async {
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(value, flush: true);
      await tmp.rename(file.path);
      return true;
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      } catch (_) {}
      return false;
    }
  }

  /// 背景 isolate 裡跑：整包編碼＋寫檔，畫面那條執行緒只付複製訊息的錢
  static bool _encodeAndWrite((String, Object?) job) =>
      _writeFileSync(File(job.$1), jsonEncode(job.$2));

  /// 新值落地後，prefs 裡搬不動而留下的舊值要清掉，不能再佔記憶體
  static Future<void> _dropPrefsCopy(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key)) await prefs.remove(key);
    } catch (_) {}
  }

  static Future<void>? _migrating;

  /// 把 prefs 裡歸這裡管的鍵搬成檔案。開 App 後主動叫一次（main.dart），
  /// 之後每次存取前也會叫——搬完就只是掃一次鍵名
  static Future<void> migrate() {
    final running = _migrating;
    if (running != null) return running;
    final job = _migrateNow().whenComplete(() => _migrating = null);
    _migrating = job;
    return job;
  }

  static Future<void> _migrateNow() async {
    final dir = await _root();
    if (dir == null) return;
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    final pending = [
      for (final k in prefs.getKeys())
        if (owns(k)) k,
    ];
    if (pending.isEmpty) return;
    var moved = 0;
    var chars = 0;
    for (final k in pending) {
      final v = prefs.get(k);
      final text = v is String ? v : (v is List ? jsonEncode(v) : null);
      if (text == null) continue;
      final file = _file(dir, k);
      // 檔案已經在（上一次搬到一半）：那就是同一份，只差 prefs 還沒刪
      if (!file.existsSync() && !await _writeFile(file, text)) continue;
      try {
        await prefs.remove(k);
      } catch (_) {
        continue;
      }
      moved++;
      chars += text.length;
      // 一筆一筆讓出去：第一次搬可能是幾百 MB，不能凍住畫面
      await Future<void>.delayed(Duration.zero);
    }
    if (moved > 0) {
      Diag.note(
        '大資料搬出設定檔：$moved 筆、約 ${(chars / 1048576).toStringAsFixed(1)}MB'
        '（草稿內容／封面、範本、貼圖改存檔案）',
      );
    }
  }

  /// 讀一筆。沒有就回 null
  static Future<String?> read(String key) async {
    await migrate();
    final dir = await _root();
    if (dir != null) {
      final file = _file(dir, key);
      final text = await _serialKey(key, () async {
        try {
          if (file.existsSync()) return await file.readAsString();
        } catch (_) {}
        return null;
      });
      if (text != null) return text;
    }
    // 沒有檔案系統，或這一筆搬不動（例如空間滿）還留在 prefs
    try {
      final v = (await SharedPreferences.getInstance()).get(key);
      return v is String ? v : (v is List ? jsonEncode(v) : null);
    } catch (_) {
      return null;
    }
  }

  /// 讀一筆字串清單（範本、貼圖）。沒有或壞掉回 null
  static Future<List<String>?> readList(String key) async {
    final s = await read(key);
    if (s == null) return null;
    try {
      final v = jsonDecode(s);
      if (v is List) return [for (final e in v) '$e'];
    } catch (_) {}
    return null;
  }

  /// 寫一筆。回傳有沒有真的寫進去
  static Future<bool> write(String key, String value) async {
    await migrate();
    final dir = await _root();
    if (dir == null) {
      return (await SharedPreferences.getInstance()).setString(key, value);
    }
    return _serialKey(key, () async {
      if (!await _writeFile(_file(dir, key), value)) return false;
      await _dropPrefsCopy(key);
      return true;
    });
  }

  /// 寫一筆「還沒編碼」的 JSON（影片草稿：整包含 Logo 的 base64，
  /// 好幾 MB）。有檔案系統時編碼跟寫檔一起丟背景 isolate，畫面那條
  /// 執行緒只付複製訊息的錢；背景起不來就退回這裡自己做
  static Future<bool> writeJson(String key, Object? value) async {
    await migrate();
    final dir = await _root();
    if (dir == null) {
      // prefs 路（web）：編碼好再寫
      return write(key, jsonEncode(value));
    }
    final file = _file(dir, key);
    return _serialKey(key, () async {
      var ok = false;
      try {
        ok = await compute(_encodeAndWrite, (file.path, value));
      } catch (_) {
        ok = false;
      }
      if (!ok) {
        try {
          ok = await _writeFile(file, jsonEncode(value));
        } catch (_) {
          ok = false; // 編碼失敗＝資料本身有問題
        }
      }
      if (ok) await _dropPrefsCopy(key);
      return ok;
    });
  }

  /// 目前會不會走檔案（同步判斷，給「要不要先在外面編碼」用）。
  /// 沒叫過 [init] 的 widget 測試一律 false
  static bool get usesFiles => !kIsWeb && (dirOverride != null || _init != null);

  static Future<bool> writeList(String key, List<String> value) async {
    if (await _root() == null) {
      return (await SharedPreferences.getInstance()).setStringList(key, value);
    }
    return write(key, jsonEncode(value));
  }

  /// 刪一筆（檔案與 prefs 裡殘留的都刪）
  static Future<bool> delete(String key) async {
    await migrate();
    var ok = true;
    final dir = await _root();
    if (dir != null) {
      final file = _file(dir, key);
      ok = await _serialKey(key, () async {
        try {
          if (file.existsSync()) await file.delete();
          return true;
        } catch (_) {
          return false;
        }
      });
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(key)) ok = await prefs.remove(key) && ok;
    return ok;
  }

  static Future<bool> exists(String key) async {
    await migrate();
    final dir = await _root();
    if (dir != null) {
      final file = _file(dir, key);
      if (await _serialKey(key, () async => file.existsSync())) return true;
    }
    return (await SharedPreferences.getInstance()).containsKey(key);
  }

  /// 這一筆佔多少位元組（檔案大小；還留在 prefs 的舊值用字數估）。
  /// 沒有就 0
  static Future<int> sizeOf(String key) async {
    await migrate();
    final dir = await _root();
    if (dir != null) {
      final file = _file(dir, key);
      final n = await _serialKey(key, () async {
        try {
          return file.existsSync() ? await file.length() : 0;
        } catch (_) {
          return 0;
        }
      });
      if (n > 0) return n;
    }
    try {
      final v = (await SharedPreferences.getInstance()).get(key);
      if (v is String) return v.length;
      if (v is List) return v.fold<int>(0, (a, e) => a + '$e'.length);
    } catch (_) {}
    return 0;
  }

  /// 以 [prefix] 開頭的鍵（檔案與 prefs 殘留合起來）
  static Future<List<String>> keysWithPrefix(String prefix) async {
    await migrate();
    final out = <String>{};
    final dir = await _root();
    if (dir != null) {
      try {
        for (final e in dir.listSync()) {
          final name = e.uri.pathSegments.last;
          if (name.startsWith(prefix) && name.endsWith('.txt')) {
            out.add(name.substring(0, name.length - 4));
          }
        }
      } catch (_) {}
    }
    for (final k in (await SharedPreferences.getInstance()).getKeys()) {
      if (k.startsWith(prefix)) out.add(k);
    }
    return out.toList();
  }
}
