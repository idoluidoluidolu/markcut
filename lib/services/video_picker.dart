import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:image_picker/image_picker.dart';
// XFile 由 image_picker 轉出來，不另外相依 cross_file

/// 系統相片選取器（安卓實作在 MainActivity.kt、iOS 在 AppDelegate.swift）。
/// 這台沒有的時候原生端回 null，呼叫端自己退回 file_picker
const _pickCh = MethodChannel('markcut/pick');

/// 相簿裡只列 GIF（會動的那種）。
///
/// 「從相簿匯入 GIF」本來開的是「所有照片」，使用者得在一整片靜態照片
/// 裡自己認哪張會動，選錯了才被擋下來（測試回報）。兩邊的系統選取器
/// 其實都篩得出來：
///   iOS  PHPicker 的 playbackStyle == imageAnimated 就是 GIF 那一類
///   安卓 系統相片選取器（ACTION_PICK_IMAGES）吃 type = image/gif
///
/// 回傳 null＝這台沒有那個選取器（Android 12 以下、Web），呼叫端要退回
/// file_picker；空清單＝使用者按了取消（不要再開第二個選取器給他）
Future<List<String>?> pickGalleryGifs() async {
  if (kIsWeb) return null;
  try {
    final r = await _pickCh.invokeMethod<List<dynamic>>('gifs');
    return r?.cast<String>();
  } catch (_) {
    // 通道出狀況就當這台沒有，退回 file_picker——匯入這件事不能因此壞掉
    return null;
  }
}

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
///
/// 回傳順序＝使用者點選的順序（時間軸照這個接）。Android 的 clipData
/// 本來就是點選順序；iOS 走的是 packages/file_picker 的修改版——
/// 上游 PHPicker 那條路是「誰先複製完誰先回」，順序會亂
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
/// 是文件選取器，使用者找不到相簿）；web 也照舊。
///
/// 回傳順序＝點選順序（見 [pickVideoFiles] 的說明；image_picker 的
/// iOS/Android 端都是照 index 填回，本來就對）
Future<List<XFile>> pickMediaFiles() => _pickOriginals(FileType.media);

/// 只挑照片（可多選）。理由同 [pickMediaFiles]；首頁的「照片批次」
/// 目前還是直接叫 ImagePicker().pickMultiImage()，換成這個就好
Future<List<XFile>> pickPhotoFiles() => _pickOriginals(FileType.image);

/// 單張素材也保留相簿原檔，避免 iOS 選圖時先重壓一次 JPEG。
Future<XFile?> pickPhotoFile() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    return file.path == null ? null : XFile(file.path!, name: file.name);
  }
  return ImagePicker().pickImage(source: ImageSource.gallery);
}

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

/// 選完才講的提醒（略過的檔案、被上限截掉的、數量偏多）。
///
/// 首頁進批次、批次中途的「＋」、拼圖進場截斷共用這一句——以前只有
/// 首頁那一次會講，中途再加兩百張、拼圖帶四十張進來都靜靜的。
/// 上限不寫在選單上：使用者還沒開始挑就先看到限制沒什麼用，
/// 挑完才講才是他真的需要知道的時候
String? pickCountHint({
  int skipped = 0,
  int count = 0,
  String unit = '個',
  int? soft,
  int dropped = 0,
  int? cap,
  String capUnit = '張',
}) {
  final parts = [
    if (skipped > 0) '已略過 $skipped 個非影片檔案',
    if (dropped > 0 && cap != null) '最多 $cap $capUnit，已略過 $dropped $capUnit',
    if (soft != null && count > soft) '選了 $count $unit，處理會比較久',
  ];
  return parts.isEmpty ? null : parts.join('；');
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
