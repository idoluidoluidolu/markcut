import 'dart:typed_data';

import 'package:gal/gal.dart';

/// 存到相簿。bytes 是什麼格式就存什麼（PNG 或 JPEG）；
/// gal 會自己依內容判斷格式，檔名不能帶副檔名（ext 在原生端用不到）
Future<String> savePhotoPng(
  Uint8List bytes,
  String name, {
  String ext = 'png',
}) async {
  if (!await Gal.hasAccess(toAlbum: true)) {
    final ok = await Gal.requestAccess(toAlbum: true);
    if (!ok) return '沒有相簿存取權限，請到系統設定開啟後再試一次';
  }
  await Gal.putImageBytes(bytes, album: '浮水印', name: name);
  // 只講存到哪。檔名（watermarker_1786605032295.png）對使用者
  // 沒有意義，放在完成視窗最大那行只是把重點蓋掉
  return '已存到「浮水印」相簿';
}
