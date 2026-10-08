import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 下載的字型放快取目錄的 fonts/：隨時抓得回來的東西不該進 iCloud 備份
///（iOS 的資料存放規範，App 審核會看）。系統空間不夠時可能被清掉——
/// 清掉就是下次用到再下載：預覽會自己去拿，匯出前沒網路會擋下來講清楚
Future<String?> fontDirPath() async {
  final base = await getApplicationCacheDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}fonts');
  if (!dir.existsSync()) await dir.create(recursive: true);
  return dir.path;
}

File _file(String dir, String name) =>
    File('$dir${Platform.pathSeparator}$name');

/// 下載好的字型在不在（大小要對：寫到一半的不算）
Future<bool> fontFileExists(String dir, String name, int size) async {
  try {
    final f = _file(dir, name);
    return await f.exists() && await f.length() == size;
  } catch (_) {
    return false;
  }
}

Future<Uint8List?> readFontFile(String dir, String name, int size) async {
  try {
    final f = _file(dir, name);
    if (!await f.exists() || await f.length() != size) return null;
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

/// 先寫 .part 再改名：寫到一半被收掉，留下的不會頂著正式檔名
Future<void> writeFontFile(String dir, String name, Uint8List bytes) async {
  final tmp = _file(dir, '$name.part');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(_file(dir, name).path);
}

/// 清掉清單以外的檔（字型換了版本、被拿掉、寫到一半的 .part）
Future<void> pruneFontFiles(String dir, Set<String> keep) async {
  try {
    await for (final e in Directory(dir).list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (!keep.contains(name)) await e.delete();
    }
  } catch (_) {}
}
