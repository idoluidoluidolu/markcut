import 'dart:js_interop';

import 'package:file_picker/file_picker.dart';
import 'package:web/web.dart' as web;

Future<({String url, String name})?> pickAudioFile() async {
  final r = await FilePicker.platform
      .pickFiles(type: FileType.audio, withData: true);
  if (r == null || r.files.isEmpty) return null;
  final f = r.files.first;
  final bytes = f.bytes;
  if (bytes == null) return null;
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'audio/mpeg'),
  );
  final url = web.URL.createObjectURL(blob);
  return (url: url, name: f.name);
}
