// 建立 VideoPlayerController 的平台切換：
// 手機用檔案路徑，Web 用 image_picker 給的 blob URL。
export 'video_controller_io.dart'
    if (dart.library.js_interop) 'video_controller_web.dart';
