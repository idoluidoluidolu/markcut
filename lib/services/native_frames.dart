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

/// 連續取 [count] 格（時間軸縮圖帶、批次條列的小格用）。
/// 一格一格排進同一條原生工作緒，不會互相搶
Future<List<Uint8List>> nativeStrip(
  String path,
  double dur,
  int count, {
  int maxH = 200,
}) async {
  final out = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    final b = await nativeFrameAt(path, dur * (i + 0.5) / count, maxH: maxH);
    if (b != null) out.add(b);
  }
  return out;
}

/// [quality] 是 JPEG 品質。拖曳預覽求快，壓得兇一點沒人看得出來；
/// 但拿去當裁切畫面的底圖時會被放大到滿版，壓縮痕跡就很明顯。
///
/// [tolMs]：允許差多少毫秒（iOS 的 AVAssetImageGenerator 容忍值；
/// 不給＝原生端預設 0.15 秒）。給得寬，解碼器就能直接拿最近的關鍵幀、
/// 一格只解一張——縮圖帶的粗抽靠這個。Android 本來就只拿關鍵幀，
/// 這個值沒作用
Future<Uint8List?> nativeFrameAt(
  String path,
  double seconds, {
  int maxH = 540,
  double quality = 0.7,
  int? tolMs,
}) async {
  try {
    return await _ch.invokeMethod<Uint8List>('frameAt', {
      'path': path,
      'ms': (seconds * 1000).round(),
      'maxH': maxH,
      'q': quality,
      'tolMs': ?tolMs,
    });
  } catch (_) {
    return null;
  }
}
