import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<Uint8List?> readFileBytes(String path) async {
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
}

Future<int> fileSizeBytes(String path) async {
  try {
    return await File(path).length();
  } catch (_) {
    return 0;
  }
}

Future<bool> fileExists(String path) async {
  try {
    return await File(path).exists();
  } catch (_) {
    return false;
  }
}

/// 把一份 bytes 變成「素材拿得到的路徑」。
/// 手機：寫進暫存檔，回檔案路徑
Future<String?> writeTempBytes(Uint8List bytes, String ext) async {
  try {
    final dir = await getTemporaryDirectory();
    final f = File(
      '${dir.path}${Platform.pathSeparator}'
      'mk_${DateTime.now().microsecondsSinceEpoch}.$ext',
    );
    await f.writeAsBytes(bytes);
    return f.path;
  } catch (_) {
    return null;
  }
}
