// 讀檔的平台切換：草稿還原時要重新載入圖片素材的位元組。
// Web 的 blob URL 重開就失效，所以 Web 版不支援草稿還原。
export 'file_reader_io.dart'
    if (dart.library.js_interop) 'file_reader_web.dart';
