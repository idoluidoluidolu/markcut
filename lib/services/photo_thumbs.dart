import 'dart:typed_data';
import 'dart:ui' as ui;

/// 一張照片「探一次」拿到的東西：像素長寬＋條列用的小縮圖
class PhotoProbe {
  const PhotoProbe(this.width, this.height, this.thumb);

  final int width;
  final int height;

  /// 長邊縮到 [probePhoto] 給的 longSide 的 PNG；本來就夠小就是原檔
  final Uint8List? thumb;

  (int, int) get dims => (width, height);
}

/// 只讀檔頭拿長寬、並以縮圖尺寸解碼一次做小縮圖。
///
/// 以前是兩段各自來：量尺寸開一次 ImageDescriptor、做縮圖再開一次
///（同一份檔案解析兩遍），而且都要先把整個檔案 readAsBytes 進 Dart
/// 堆。這裡：
/// - 有 [path]（手機）就用 [ui.ImmutableBuffer.fromFilePath]，檔案由
///   引擎那邊直接讀，不經 Dart 堆、不多複製一份；[readBytes] 只在
///   真的需要位元組時（檔案本來就比縮圖小、或退路）才呼叫；
/// - 同一個 descriptor 既拿尺寸也開縮圖 codec（解碼器只看一次檔頭）；
/// - 縮圖用 targetWidth/targetHeight 讓解碼器在解的時候就縮
///  （JPEG 是 DCT 縮放、HEIC 是 ImageIO 縮圖），不是解整張再縮。
///
/// [ui.ImageDescriptor] 在 web 會炸：退回逐格解碼——但只解一次
///（尺寸從解出來的整張圖拿、縮圖從同一張圖畫出來），不像以前解兩次
Future<PhotoProbe?> probePhoto({
  String? path,
  required Future<Uint8List> Function() readBytes,
  required int longSide,
}) async {
  ui.ImmutableBuffer? buf;
  ui.ImageDescriptor? desc;
  try {
    buf = path != null
        ? await ui.ImmutableBuffer.fromFilePath(path)
        : await ui.ImmutableBuffer.fromUint8List(await readBytes());
    desc = await ui.ImageDescriptor.encoded(buf);
    final w = desc.width, h = desc.height;
    if (w == 0 || h == 0) return null;
    final long = w > h ? w : h;
    if (long <= longSide) {
      // 本來就夠小，原檔就是縮圖
      return PhotoProbe(w, h, await readBytes());
    }
    final scale = longSide / long;
    final codec = await desc.instantiateCodec(
      targetWidth: (w * scale).round().clamp(1, longSide),
      targetHeight: (h * scale).round().clamp(1, longSide),
    );
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return PhotoProbe(w, h, png?.buffer.asUint8List());
  } catch (_) {
    // web（或壞檔）：逐格解碼一次，尺寸跟縮圖都從這一張出
    try {
      final src = await readBytes();
      final codec = await ui.instantiateImageCodec(src);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final w = img.width, h = img.height;
      final long = w > h ? w : h;
      Uint8List? thumb;
      if (long <= longSide) {
        thumb = src;
      } else {
        final scale = longSide / long;
        final tw = (w * scale).round().clamp(1, longSide);
        final th = (h * scale).round().clamp(1, longSide);
        final rec = ui.PictureRecorder();
        ui.Canvas(rec).drawImageRect(
          img,
          ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          ui.Rect.fromLTWH(0, 0, tw.toDouble(), th.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        final small = await rec.endRecording().toImage(tw, th);
        thumb = (await small.toByteData(
          format: ui.ImageByteFormat.png,
        ))?.buffer.asUint8List();
        small.dispose();
      }
      img.dispose();
      codec.dispose();
      return PhotoProbe(w, h, thumb ?? src);
    } catch (_) {
      return null;
    }
  } finally {
    desc?.dispose();
    buf?.dispose();
  }
}
