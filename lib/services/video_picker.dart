import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:image_picker/image_picker.dart';
// XFile 由 image_picker 轉出來，不另外相依 cross_file

/// 安卓的系統相片選取器（原生端實作在 MainActivity.kt）。
/// Android 12 以下沒有這個東西，原生端會回 null
const _pickCh = MethodChannel('markcut/pick');

/// 只挑影片：相簿裡就只列得出影片，不會混著照片一起給。
///
/// image_picker 沒有「只選影片、而且可以多選」的 API——pickVideo 只能
/// 挑一支，pickMultipleMedia 則是照片影片混在一起，挑完還要自己濾掉
/// 照片（使用者看得到照片、點得下去，最後卻被告知不能用）。
///
/// Android 13+：走系統相片選取器（開出來就是相簿、只列影片）。
/// file_picker 的 FileType.video 在安卓其實是 SAF 文件選取器，
/// 開出來是檔案管理器的「最近」——使用者反映找不到影片。
/// iOS 與舊安卓照舊走 file_picker；Web 拿不到檔案路徑，退回混合選取再濾
Future<List<XFile>> pickVideoFiles() async {
  if (kIsWeb) {
    final list = await ImagePicker().pickMultipleMedia();
    return list.where(isVideoFile).toList();
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      final r = await _pickCh.invokeMethod<List<dynamic>>('videos', {
        'max': 100, // 選取器的上限；App 的軟性上限在挑完之後才提醒
      });
      if (r != null) {
        return [
          for (final p in r.cast<String>()) XFile(p, name: p.split('/').last),
        ];
      }
      // null＝這台沒有系統相片選取器（Android 12 以下），往下走 SAF
    } catch (_) {
      // 通道出狀況也退回 SAF，選影片這件事不能因此壞掉
    }
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

/// 相簿混選（照片＋影片、可多選）：批次頁中途那顆「＋」用。
///
/// iOS 走 file_picker，拿到的是相簿裡的「原檔」（HEIC 就是 HEIC，只做
/// 檔案複製）。image_picker 的 iOS 端不是這樣：每一張都先整張解成
/// 點陣、再用 UIImageJPEGRepresentation(1.0) 壓一次 JPEG、再把 EXIF
/// 塞回去——挑 30 張 12MP 就是 30 次全解析度解碼＋編碼之後才把控制權
/// 還給 App，而且 q=1.0 的 JPEG 比原檔大兩三倍，之後每一步讀檔、
/// 解碼都跟著慢。
///
/// Android 照舊 image_picker（系統相片選取器；file_picker 在安卓開的
/// 是文件選取器，使用者找不到相簿）；web 也照舊
Future<List<XFile>> pickMediaFiles() => _pickOriginals(FileType.media);

/// 只挑照片（可多選）。理由同 [pickMediaFiles]；首頁的「照片批次」
/// 目前還是直接叫 ImagePicker().pickMultiImage()，換成這個就好
Future<List<XFile>> pickPhotoFiles() => _pickOriginals(FileType.image);

Future<List<XFile>> _pickOriginals(FileType type) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    // compressionQuality 預設 0 ＝ 不壓：PHPicker 用 .current 表示法，
    // 系統不轉檔、file_picker 只 copy 檔案
    final r = await FilePicker.platform.pickFiles(
      type: type,
      allowMultiple: true,
    );
    return [
      for (final f in r?.files ?? const <PlatformFile>[])
        if (f.path != null) XFile(f.path!, name: f.name),
    ];
  }
  final picker = ImagePicker();
  return type == FileType.image
      ? picker.pickMultiImage()
      : picker.pickMultipleMedia();
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
