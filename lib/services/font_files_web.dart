import 'dart:typed_data';

/// Web 沒有檔案系統：不存檔，每次開頁面用到再下載
Future<String?> fontDirPath() async => null;

Future<bool> fontFileExists(String dir, String name, int size) async => false;

Future<Uint8List?> readFontFile(String dir, String name, int size) async =>
    null;

Future<void> writeFontFile(String dir, String name, Uint8List bytes) async {}

Future<void> pruneFontFiles(String dir, Set<String> keep) async {}
