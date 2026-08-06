// 影片處理引擎的平台切換：
// 手機/桌面用 FFmpeg（video_engine_io.dart），
// Web 沒有 FFmpeg，改用 stub（video_engine_web.dart）只提供預覽。
export 'video_engine_io.dart'
    if (dart.library.js_interop) 'video_engine_web.dart';
