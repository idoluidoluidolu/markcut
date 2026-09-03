import 'dart:io';

/// 刪 HDR 匯出的暫存 HEIC（已存進相簿）。失敗無所謂，系統遲早清 tmp
void deletePhotoTemp(String path) {
  try {
    File(path).deleteSync();
  } catch (_) {}
}
