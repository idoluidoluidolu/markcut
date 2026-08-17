import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
// XFile 由 image_picker 轉出來，不另外相依 cross_file

/// 只挑影片：相簿裡就只列得出影片，不會混著照片一起給。
///
/// image_picker 沒有「只選影片、而且可以多選」的 API——pickVideo 只能
/// 挑一支，pickMultipleMedia 則是照片影片混在一起，挑完還要自己濾掉
/// 照片（使用者看得到照片、點得下去，最後卻被告知不能用）。
/// file_picker 的 FileType.video 在 iOS／Android 都是相簿本人，
/// 只是先幫我們濾好了。
///
/// Web 沒有這條路（拿不到檔案路徑），退回混合選取再濾
Future<List<XFile>> pickVideoFiles() async {
  if (kIsWeb) {
    final list = await ImagePicker().pickMultipleMedia();
    return list.where(isVideoFile).toList();
  }
  final r = await FilePicker.platform.pickFiles(
    type: FileType.video,
    allowMultiple: true,
  );
  return [
    for (final f in r?.files ?? const <PlatformFile>[])
      if (f.path != null) XFile(f.path!, name: f.name),
  ];
}

/// 這個檔是影片嗎。優先看 mimeType，拿不到就退回看副檔名
///（相簿匯出的檔案不一定帶 mime）
bool isVideoFile(XFile f) {
  final mime = f.mimeType;
  if (mime != null && mime.isNotEmpty) return mime.startsWith('video/');
  final ext = f.name.toLowerCase().split('.').last;
  return const {
    'mp4',
    'mov',
    'm4v',
    'avi',
    'mkv',
    'webm',
    '3gp',
    'ts',
    'mts',
  }.contains(ext);
}
