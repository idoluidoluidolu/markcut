import 'package:file_picker/file_picker.dart';

Future<({String url, String name})?> pickAudioFile() async {
  final r = await FilePicker.platform.pickFiles(type: FileType.audio);
  if (r == null || r.files.isEmpty) return null;
  final f = r.files.first;
  if (f.path == null) return null;
  return (url: f.path!, name: f.name);
}
