// 選音樂檔的平台切換：手機回傳檔案路徑（FFmpeg 可讀），
// Web 回傳 blob URL（僅供預覽播放）。
export 'audio_picker_io.dart'
    if (dart.library.js_interop) 'audio_picker_web.dart';
