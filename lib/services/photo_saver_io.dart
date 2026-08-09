import 'dart:typed_data';

import 'package:gal/gal.dart';

/// 存到相簿。bytes 是什麼格式就存什麼（PNG 或 JPEG），
/// ext 只影響檔名
Future<String> savePhotoPng(
  Uint8List bytes,
  String name, {
  String ext = 'png',
}) async {
  if (!await Gal.hasAccess(toAlbum: true)) {
    await Gal.requestAccess(toAlbum: true);
  }
  await Gal.putImageBytes(bytes, album: '浮水印', name: name);
  return '完成！照片已儲存到相簿（浮水印 相簿）';
}
