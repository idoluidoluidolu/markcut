// 照片輸出的平台切換：手機存到相簿，Web 觸發瀏覽器下載。
export 'photo_saver_io.dart'
    if (dart.library.js_interop) 'photo_saver_web.dart';
