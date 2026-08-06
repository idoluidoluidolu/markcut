import 'dart:io';
import 'dart:typed_data';

Future<Uint8List?> readFileBytes(String path) async {
  try {
    return await File(path).readAsBytes();
  } catch (_) {
    return null;
  }
}

Future<bool> fileExists(String path) async {
  try {
    return await File(path).exists();
  } catch (_) {
    return false;
  }
}
