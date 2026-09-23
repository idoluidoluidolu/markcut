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
/// 檔案讀寫用同步版：成本跟以前 prefs 一樣（那也是在這條執行緒上把整串
/// 字串編碼送出去），而 widget 測試的假時間裡，非同步 I/O 永遠等不到回來
class BlobStore {
  BlobStore._();

  /// 這些前綴的鍵歸這裡管（影片草稿內容與封面）
  static const ownedPrefixes = ['project_data_', 'project_thumb_'];

  /// 這些鍵歸這裡管（範本與貼圖；prefs 裡是字串清單，檔案裡是 JSON 陣列）
  static const ownedKeys = {'wm_presets_v1', 'stickers_v1'};

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

  /// 先寫暫存檔再換名：寫到一半被系統殺掉，原本那份還在
  static bool _writeFile(File file, String value) {
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
      if (!file.existsSync() && !_writeFile(file, text)) continue;
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
      try {
        if (file.existsSync()) return file.readAsStringSync();
      } catch (_) {}
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
    final prefs = await SharedPreferences.getInstance();
    if (dir == null) return prefs.setString(key, value);
    if (!_writeFile(_file(dir, key), value)) return false;
    // 搬不動而留在 prefs 的舊值：新值已經落地，舊的不能再佔記憶體
    if (prefs.containsKey(key)) await prefs.remove(key);
    return true;
  }

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
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {
        ok = false;
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(key)) ok = await prefs.remove(key) && ok;
    return ok;
  }

  static Future<bool> exists(String key) async {
    await migrate();
    final dir = await _root();
    if (dir != null && _file(dir, key).existsSync()) return true;
    return (await SharedPreferences.getInstance()).containsKey(key);
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
