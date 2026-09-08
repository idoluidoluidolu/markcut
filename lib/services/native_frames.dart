import 'package:flutter/services.dart';

/// 按需抽取影片的粗覽影格：iOS 使用 AVAssetImageGenerator，Android
/// 使用 MediaMetadataRetriever。解碼方式和耗時由來源編碼、解析度、
/// 關鍵幀距離與裝置決定；此通道不保證硬體解碼或固定延遲。
///
/// 回傳 JPEG 適合拖曳粗覽；iOS 會處理 HDR 到 SDR 的轉換，它並不等同
/// 系統播放器最終 HDR／EDR 呈現。精準落點與輸出仍由原始素材管線負責。
/// 拿不到（web、平台不支援、檔案壞了）回 null，讓呼叫端保留退路。
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
/// 不給＝原生端預設 0.15 秒）。放寬可增加解碼彈性，但不保證最近
/// 關鍵幀或指定時間；需要判斷實際取樣時間時用 [nativeFrameAtDetailed]。
/// Android 只拿關鍵幀，這個值沒作用。
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

/// 一張取樣影格及原生確認的來源時間。舊版原生／Android 僅回 bytes，
/// [actualSeconds] 保持 null，不能拿請求時間冒充實际的關鍵幀時間。
class NativeFrameSample {
  const NativeFrameSample({required this.bytes, this.actualSeconds});

  final Uint8List bytes;
  final double? actualSeconds;

  static NativeFrameSample? fromPlatform(Object? value) {
    if (value is Uint8List) return NativeFrameSample(bytes: value);
    if (value is! Map || value['bytes'] is! Uint8List) return null;
    final rawTime = value['actualSeconds'];
    final time = rawTime is num ? rawTime.toDouble() : null;
    return NativeFrameSample(
      bytes: value['bytes'] as Uint8List,
      actualSeconds: time != null && time.isFinite && time >= 0 ? time : null,
    );
  }

  /// 粗覽可使用沒有時間資訊的舊平台結果；已知取樣時間則必須接近目標。
  /// true 不代表精準落點，最終停手仍由播放器的精準 seek 確認。
  bool usableForPreviewAt(double seconds, {double maxDrift = 0.25}) =>
      actualSeconds == null || (actualSeconds! - seconds).abs() <= maxDrift;
}

Future<NativeFrameSample?> nativeFrameAtDetailed(
  String path,
  double seconds, {
  int maxH = 540,
  double quality = 0.7,
  int? tolMs,
}) async {
  try {
    return NativeFrameSample.fromPlatform(
      await _ch.invokeMethod<Object?>('frameAt', {
        'path': path,
        'ms': (seconds * 1000).round(),
        'maxH': maxH,
        'q': quality,
        'tolMs': ?tolMs,
        'detailed': true,
      }),
    );
  } catch (_) {
    return null;
  }
}

/// 離開編輯器時釋放原生重用的抽幀器。未實作的舊平台可安全忽略。
Future<void> releaseNativeFrames() async {
  try {
    await _ch.invokeMethod<void>('release');
  } catch (_) {}
}

typedef NativeFrameStats = ({
  int active,
  int created,
  int reused,
  int capacity,
});

/// 原生抽幀器的存量與重用次數，與影格產生／顯示 FPS 無關。
Future<NativeFrameStats?> readNativeFrameStats() async {
  try {
    final stats = await _ch.invokeMapMethod<String, dynamic>('stats');
    if (stats == null) return null;
    return (
      active: (stats['active'] as num).toInt(),
      created: (stats['created'] as num).toInt(),
      reused: (stats['reused'] as num).toInt(),
      capacity: (stats['capacity'] as num).toInt(),
    );
  } catch (_) {
    return null;
  }
}
