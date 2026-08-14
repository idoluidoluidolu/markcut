import 'package:flutter/services.dart';

/// 跟「系統的硬體解碼器」要影片某個時間點的一格。
///
/// 拖曳預覽走這裡，不再等 FFmpeg 把整支影片預先抽完：
/// - iOS 用 AVAssetImageGenerator、Android 用 MediaMetadataRetriever，
///   都是硬體解碼，一格約幾十毫秒，滑到哪要到哪；
/// - HDR 的色調映射由系統做，跟播放畫面天生一致——不用再維護
///   自己的轉換鏈（FFmpeg 那條只剩匯出在用）；
/// - 原生端實作在 ios/Runner/AppDelegate.swift 與 android 的
///   MainActivity.kt，各三十行左右。
///
/// 拿不到（web、平台不支援、檔案壞了）回 null，呼叫端自己有退路
const _ch = MethodChannel('markcut/frames');

Future<Uint8List?> nativeFrameAt(
  String path,
  double seconds, {
  int maxH = 540,
}) async {
  try {
    return await _ch.invokeMethod<Uint8List>('frameAt', {
      'path': path,
      'ms': (seconds * 1000).round(),
      'maxH': maxH,
    });
  } catch (_) {
    return null;
  }
}
