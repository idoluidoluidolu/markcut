import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'video_processor.dart';

/// Web 版沒有 FFmpeg，只提供介面預覽，不支援影片匯出。
const bool videoExportSupported = false;

/// Web 沒有 FFmpeg，做不了倒轉檔——回 null，介面會退回抽幀預覽模式
Future<String?> renderReversedClip(
  String srcPath,
  double trimStart,
  double trimEnd,
  int targetW,
  int targetH, {
  void Function(double progress)? onProgress,
}) async => null;

Future<({bool ok, String message, bool cancelled})> exportVideoToGallery(
  ExportSpec spec, {
  void Function(double progress)? onProgress,
}) async {
  return (
    ok: false,
    message: 'Web 版僅供預覽測試，影片匯出請用手機 App',
    cancelled: false,
  );
}

/// 取消匯出（Web 版沒有匯出，不用做事）
Future<void> cancelExport() async {}

/// Web 沒有 FFmpeg，不做 HDR 轉換（診斷報告會照實寫）
Future<String> hdrChainName() async => '不適用（web 沒有 FFmpeg）';

/// Web 量不到（素材是 blob URL），回空值＝畫質自動挑不啟用
Future<({String codec, double fps, int w, int h})> probeVideoInfo(
  String path,
) async => (codec: '', fps: 0.0, w: 0, h: 0);

/// Web 沒有 FFmpeg：用隱形 <video> + canvas 抓格做縮圖，
/// 時間軸 filmstrip 與草稿封面才有畫面
/// Web 沒有 FFmpeg，做不出 GIF（GIF 相關的入口在 web 上本來就隱藏，
/// 這裡只是讓兩邊的介面對得起來）
Future<String?> makeGifFile({
  required String inputPath,
  required double start,
  required double end,
  required int fps,
  required int maxSide,
}) async => null;

Future<List<Uint8List>> makeThumbnails(
    String inputPath, double durationSec, int count,
    {int height = 200,
    bool longSide = false,
    double startAt = 0,
    bool fastDecode = false}) async {
  // fastDecode 在 Web 不需要：<video> 是硬體解碼
  try {
    final video = web.HTMLVideoElement()
      ..src = inputPath
      ..muted = true
      ..preload = 'auto';

    final loaded = Completer<void>();
    video.onloadeddata = ((web.Event e) {
      if (!loaded.isCompleted) loaded.complete();
    }).toJS;
    video.onerror = ((web.Event e) {
      if (!loaded.isCompleted) loaded.completeError('video load error');
    }).toJS;
    await loaded.future.timeout(const Duration(seconds: 8));

    final w = video.videoWidth;
    final h = video.videoHeight;
    if (w == 0 || h == 0) return [];
    // startAt > 0＝只抽 [startAt, startAt+durationSec) 這段
    final dur = startAt > 0.001
        ? durationSec
        : (video.duration.isFinite && video.duration > 0
            ? video.duration
            : durationSec);

    // longSide＝把「長邊」縮到 height（直式影片才不會糊）
    final scale = longSide
        ? height / math.max(w, h)
        : height / h;
    final targetH = (h * scale).round().clamp(2, 2048);
    final targetW = (w * scale).round().clamp(2, 2048);
    final canvas = web.HTMLCanvasElement()
      ..width = targetW
      ..height = targetH;
    final ctx = canvas.context2D;
    ctx.scale(targetW / w, targetH / h);

    Completer<void> seeked = Completer<void>();
    video.onseeked = ((web.Event e) {
      if (!seeked.isCompleted) seeked.complete();
    }).toJS;

    final result = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      seeked = Completer<void>();
      video.currentTime = startAt + dur * (i + 0.5) / count;
      try {
        await seeked.future.timeout(const Duration(seconds: 4));
      } catch (_) {
        break;
      }
      ctx.drawImage(video, 0, 0);
      // toBlob＝非同步編碼（Chrome 在背景緒做），
      // 不像 toDataURL 會卡住主執行緒讓播放跳針
      final blobDone = Completer<Uint8List?>();
      canvas.toBlob(
        ((web.Blob? b) {
          if (b == null) {
            blobDone.complete(null);
            return;
          }
          b.arrayBuffer().toDart.then(
              (buf) => blobDone.complete(buf.toDart.asUint8List()),
              onError: (_) => blobDone.complete(null));
        }).toJS,
        'image/jpeg',
        0.82.toJS,
      );
      final bytes =
          await blobDone.future.timeout(const Duration(seconds: 4));
      if (bytes != null) result.add(bytes);
      // 讓 UI 喘口氣，抽幀永遠讓路給播放
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    return result;
  } catch (_) {
    return [];
  }
}
