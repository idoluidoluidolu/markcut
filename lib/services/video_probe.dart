// 播放偵測的平台切換：只有裝置端有原生解碼器可以驗，
// Web 是一句「不支援」的 stub
export 'video_probe_io.dart'
    if (dart.library.js_interop) 'video_probe_web.dart';
