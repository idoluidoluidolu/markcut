import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<String> savePhotoPng(Uint8List pngBytes, String name) async {
  final blob = web.Blob(
    [pngBytes.toJS].toJS,
    web.BlobPropertyBag(type: 'image/png'),
  );
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..download = '$name.png'
    ..click();
  web.URL.revokeObjectURL(url);
  return '完成！照片已下載（$name.png）';
}
