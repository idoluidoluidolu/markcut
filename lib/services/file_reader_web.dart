import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uint8List?> readFileBytes(String path) async => null;

/// Web 的素材是 blob URL，量不到大小；回 0 表示「無從判斷」
Future<int> fileSizeBytes(String path) async => 0;

Future<bool> fileExists(String path) async => false;

/// 把一份 bytes 變成「素材拿得到的路徑」。
/// Web：做一個 blob URL。不 revoke——素材還要一直讀它
Future<String?> writeTempBytes(Uint8List bytes, String ext) async {
  final mime = ext == 'jpg' ? 'image/jpeg' : 'image/png';
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
  return web.URL.createObjectURL(blob);
}
