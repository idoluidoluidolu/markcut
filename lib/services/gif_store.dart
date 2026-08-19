import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// 做好的 GIF 留一份在 App 裡（個人中心的「我的 GIF」）。
///
/// 存到相簿之後就把暫存檔刪掉的話，想再拿它當素材只能回相簿找——
/// 而相簿把 GIF 當一般圖片，跟幾千張照片混在一起。這裡另外留一份，
/// 匯入 GIF 素材時直接從這裡挑。
///
/// 放在文件目錄不是快取目錄：快取會被系統回收，做好的東西不該
/// 自己消失。
///
/// 每一筆用「參照字串」表示：手機上是檔案路徑，Web 的展示模式是
/// `asset:` 開頭的內建範例（見 [demoRefs]）
class GifStore {
  /// Web 沒有 FFmpeg，做不出 GIF。但整套流程還是要看得到長什麼樣，
  /// 所以 Web 一律回這三個內建範例——直式、方形、橫式各一個，
  /// 剛好看得出瀑布流照原始比例排
  static const demoRefs = <String>[
    'asset:assets/demo/demo_bounce.gif',
    'asset:assets/demo/demo_spin.gif',
    'asset:assets/demo/demo_bars.gif',
  ];

  /// 這個參照是內建範例還是真的檔案
  static bool isAsset(String ref) => ref.startsWith('asset:');

  /// 去掉 `asset:` 前綴
  static String assetKey(String ref) => ref.substring(6);

  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}gifs');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 全部的 GIF（新到舊）
  static Future<List<String>> list() async {
    if (kIsWeb) return demoRefs;
    try {
      final d = await _dir();
      final files = d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.gif'))
          .toList();
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      return [for (final f in files) f.path];
    } catch (_) {
      return [];
    }
  }

  /// 這一筆的位元組（要量比例、或要當素材匯入時用）
  static Future<Uint8List?> bytes(String ref) async {
    try {
      if (isAsset(ref)) {
        final d = await rootBundle.load(assetKey(ref));
        return d.buffer.asUint8List();
      }
      return await File(ref).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 這個路徑是不是已經在我的 GIF 裡（在的話就不用再收一份）
  static Future<bool> isStored(String path) async {
    if (kIsWeb || isAsset(path)) return false;
    try {
      final d = await _dir();
      return path.startsWith(d.path);
    } catch (_) {
      return false;
    }
  }

  /// 直接用位元組收一份進來。相簿挑出來的檔案放在暫存目錄，
  /// 系統隨時會清掉——存成草稿之後就找不到了，所以一律留一份自己的
  static Future<String?> addBytes(Uint8List bytes) async {
    if (kIsWeb) return null;
    try {
      final d = await _dir();
      final name = 'gif_${DateTime.now().millisecondsSinceEpoch}.gif';
      final dest = '${d.path}${Platform.pathSeparator}$name';
      await File(dest).writeAsBytes(bytes);
      return dest;
    } catch (_) {
      return null;
    }
  }

  /// 收一份進來。回傳存好的路徑，失敗回 null
  static Future<String?> add(String srcPath) async {
    if (kIsWeb) return null;
    try {
      final d = await _dir();
      final name = 'gif_${DateTime.now().millisecondsSinceEpoch}.gif';
      final dest = '${d.path}${Platform.pathSeparator}$name';
      await File(srcPath).copy(dest);
      return dest;
    } catch (_) {
      return null;
    }
  }

  static Future<void> remove(String ref) async {
    if (kIsWeb || isAsset(ref)) return;
    try {
      final f = File(ref);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
