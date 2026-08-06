import 'dart:typed_data';

import 'package:gal/gal.dart';

Future<String> savePhotoPng(Uint8List pngBytes, String name) async {
  if (!await Gal.hasAccess(toAlbum: true)) {
    await Gal.requestAccess(toAlbum: true);
  }
  await Gal.putImageBytes(pngBytes, album: '浮水印', name: name);
  return '完成！照片已儲存到相簿（浮水印 相簿）';
}
