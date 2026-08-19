import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 做好的 GIF 留一份在 App 裡（個人中心的「我的 GIF」）。
///
/// 存到相簿之後就把暫存檔刪掉的話，想再拿它當素材只能回相簿找——
/// 而相簿把 GIF 當一般圖片，跟幾千張照片混在一起。這裡另外留一份，
/// 匯入 GIF 素材時直接從這裡挑。
///
/// 放在文件目錄不是快取目錄：快取會被系統回收，做好的東西不該
/// 自己消失
class GifStore {
  static Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}gifs');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 全部的 GIF（新到舊）
  static Future<List<File>> list() async {
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
      return files;
    } catch (_) {
      return [];
    }
  }

  /// 收一份進來。回傳存好的路徑，失敗回 null
  static Future<String?> add(String srcPath) async {
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

  static Future<void> remove(String path) async {
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}
