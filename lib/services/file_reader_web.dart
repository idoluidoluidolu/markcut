import 'dart:typed_data';

Future<Uint8List?> readFileBytes(String path) async => null;

/// Web 的素材是 blob URL，量不到大小；回 0 表示「無從判斷」
Future<int> fileSizeBytes(String path) async => 0;

Future<bool> fileExists(String path) async => false;
