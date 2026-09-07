import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// 批次浮水印／拼圖草稿引用的素材，自己留一份在 Application Support。
///
/// 相簿選取器交出來的都是複本：iOS 的 file_picker（PHPicker 那條）放在
/// Documents/picked_images、文件選取器放在 tmp/；image_picker 跟安卓的
/// 系統相片選取器放在 cache/。tmp／cache 系統隨時可清（iOS 幾天就清），
/// 草稿記那些路徑，過幾天續作就是「有 N 個檔案已不在」；Documents 那邊
/// 反過來永遠不會被清、每挑一次就多一份原檔，幾百 MB 就這樣堆著。
/// GIF 那頁早就自己留一份（GifStore.addBytes），照片草稿以前沒有。
///
/// 做法：存草稿時把引用的檔案複製進 `support/draft_assets/<kind>/`，草稿改記
/// 複本；離開頁面時把「這一頁收到、草稿沒在用」的選取器複本刪掉。
/// 複本的位置由來源路徑決定（同一個來源永遠對到同一個複本），所以
/// 再存一次草稿不會再複製一份，草稿記的路徑不見了也還能照來源路徑
/// 找回複本（[resolve]）
class DraftAssets {
  static const _root = 'draft_assets';

  /// 批次浮水印／拼圖各自一格，清理時互不干擾
  static const batch = 'batch';
  static const collage = 'collage';

  /// 測試用：把 Application Support 換成一個暫存目錄（真機不會設）
  @visibleForTesting
  static Directory? supportDirOverride;

  /// 測試用：把「選取器會把複本放在哪」換成指定的目錄
  @visibleForTesting
  static List<Directory>? pickerRootsOverride;

  static Future<Directory> _support() async =>
      supportDirOverride ?? await getApplicationSupportDirectory();

  static Future<Directory> _dir(String kind) async {
    final base = await _support();
    final sep = Platform.pathSeparator;
    return Directory('${base.path}$sep$_root$sep$kind');
  }

  /// 這條路徑是不是 [kind] 這一格裡的複本
  static bool _inside(String path, Directory dir) {
    final sep = Platform.pathSeparator;
    final prefix = dir.path.endsWith(sep) ? dir.path : '${dir.path}$sep';
    if (path.startsWith(prefix)) return true;
    // 符號連結（iOS 的 /var 與 /private/var）兩邊各自解一次再比
    try {
      final rp = File(path).resolveSymbolicLinksSync();
      final rd = dir.resolveSymbolicLinksSync();
      return rp.startsWith(rd.endsWith(sep) ? rd : '$rd$sep');
    } catch (_) {
      return false;
    }
  }

  /// 來源路徑 → 複本的固定位置。FNV-1a（32 位元，web 也算得動）
  /// 當資料夾名、檔名照舊——副檔名要留著，下游是照副檔名認影片的
  static String _slot(String src) {
    var h = 0x811c9dc5;
    for (final c in src.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    // 長度混進去：短路徑的雜湊差一位就撞，多一道保險
    h = ((h ^ src.length) * 0x01000193) & 0xffffffff;
    return h.toRadixString(16).padLeft(8, '0');
  }

  static String _name(String src) {
    final n = src.split(Platform.pathSeparator).last.split('/').last;
    return n.isEmpty ? 'asset' : n;
  }

  static Future<String> _dest(String kind, String src) async {
    final d = await _dir(kind);
    final sep = Platform.pathSeparator;
    return '${d.path}$sep${_slot(src)}$sep${_name(src)}';
  }

  /// 把 [src] 留一份進來，回傳複本路徑。已經是複本就直接回它；
  /// 複製不成（空間不足、來源不見了）回 null，呼叫端照記原路徑
  static Future<String?> secure(String kind, String src) async {
    if (kIsWeb || src.isEmpty) return null;
    try {
      final dir = await _dir(kind);
      if (_inside(src, dir)) return src;
      final source = File(src);
      if (!await source.exists()) return null;
      final dest = await _dest(kind, src);
      final out = File(dest);
      // 同一個來源已經留過一份：不再複製。大小對不上＝上次複製到一半
      // 被殺掉了，重來
      if (await out.exists() && await out.length() == await source.length()) {
        return dest;
      }
      await out.parent.create(recursive: true);
      try {
        await source.copy(dest);
      } catch (_) {
        try {
          await out.delete();
        } catch (_) {}
        return null;
      }
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// 草稿記的路徑現在該讀哪裡：還在就是它；不在了但留過複本就用複本；
  /// 兩邊都沒有回 null（這張真的找不回來了）
  static Future<String?> resolve(String kind, String path) async {
    if (path.isEmpty) return null;
    try {
      if (await File(path).exists()) return path;
      if (kIsWeb) return null;
      final alt = await _dest(kind, path);
      if (await File(alt).exists()) return alt;
    } catch (_) {}
    return null;
  }

  /// 只留 [keep] 裡的複本，其餘刪掉（草稿存了新的一版、或草稿被刪掉了）
  static Future<int> retain(String kind, Set<String> keep) async {
    if (kIsWeb) return 0;
    var n = 0;
    try {
      final dir = await _dir(kind);
      if (!await dir.exists()) return 0;
      await for (final e in dir.list(recursive: true)) {
        if (e is! File) continue;
        if (keep.contains(e.path)) continue;
        try {
          await e.delete();
          n++;
        } catch (_) {}
      }
      // 空掉的資料夾一起收
      await for (final e in dir.list()) {
        if (e is Directory && await e.list().isEmpty) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return n;
  }

  /// 選取器會把複本放在哪：tmp／cache（[getTemporaryDirectory]）、
  /// iOS file_picker 的 Documents/picked_images
  static Future<List<Directory>> _pickerRoots() async {
    final o = pickerRootsOverride;
    if (o != null) return o;
    final roots = <Directory>[];
    try {
      roots.add(await getTemporaryDirectory());
    } catch (_) {}
    try {
      final docs = await getApplicationDocumentsDirectory();
      roots.add(
        Directory('${docs.path}${Platform.pathSeparator}picked_images'),
      );
    } catch (_) {}
    return roots;
  }

  /// 把選取器交出來的複本刪掉（[keep] 裡的除外）。
  ///
  /// 只刪「確定是選取器複本」的：路徑落在選取器的暫存位置底下、又不是
  /// 我們自己留的草稿複本。使用者相簿的原檔、桌面上直接選到的真檔案
  /// 一律不碰——選取器在那些平台給的是原路徑
  static Future<int> discardPickerCopies(
    Iterable<String> paths, {
    required Set<String> keep,
  }) async {
    if (kIsWeb) return 0;
    var n = 0;
    try {
      final roots = await _pickerRoots();
      if (roots.isEmpty) return 0;
      final own = Directory(
        '${(await _support()).path}${Platform.pathSeparator}$_root',
      );
      for (final p in {...paths}) {
        if (p.isEmpty || keep.contains(p)) continue;
        if (_inside(p, own)) continue;
        if (!roots.any((r) => _inside(p, r))) continue;
        final f = File(p);
        try {
          if (!await f.exists()) continue;
          await f.delete();
          n++;
          // 安卓的系統選取器一次挑選一個資料夾（cache/picked/<uuid>/）：
          // 檔案刪光就把空資料夾一起收，不然殼子愈積愈多
          final parent = f.parent;
          if (!roots.any((r) => r.path == parent.path) &&
              await parent.list().isEmpty) {
            await parent.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
    return n;
  }

  /// 離開頁面時的整套清理：草稿沒在用的複本、這一頁收到的選取器複本
  static Future<void> afterLeave(
    String kind, {
    required Set<String> keep,
    required Iterable<String> received,
  }) async {
    await retain(kind, keep);
    await discardPickerCopies(received, keep: keep);
  }
}
