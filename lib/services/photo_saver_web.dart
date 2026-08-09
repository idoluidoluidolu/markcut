import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// 觸發瀏覽器下載。bytes 是什麼格式就存什麼（PNG 或 JPEG）
Future<String> savePhotoPng(
  Uint8List bytes,
  String name, {
  String ext = 'png',
}) async {
  final mime = ext == 'jpg' ? 'image/jpeg' : 'image/png';
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = '\$name.\$ext'
    ..click();
  web.URL.revokeObjectURL(url);
  return '完成！照片已下載（\$name.\$ext）';
}
