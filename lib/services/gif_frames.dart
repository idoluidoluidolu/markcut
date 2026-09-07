import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'gif_store.dart';

/// GIF 成品預覽的幀：解好、縮到預覽用得到的大小，常駐記憶體受總量上限管。
///
/// 每一幀都是 RGBA 點陣：640p、15fps、15 秒＝225 幀，每幀 0.9~1.6MB，
/// 整支留著就是 200~370MB；速度 0.25× 的成品 60 秒到上限 400 幀就是
/// 半 GB——匯出時還跟 FFmpeg 同時活著，舊機器直接被 jetsam 收掉。
/// 預覽區才幾百 pt 寬，幀不必比它大；再多也不能超過 [kGifFrameBudget]，
/// 超過就整批再縮一階（畫面軟一點，總比 App 消失好）。
///
/// 縮圖不能交給 instantiateCodec(targetWidth:)：多幀的 codec 會把目標
/// 尺寸整個忽略（探針實測：100×60 的三幀 GIF 給 targetWidth 10 還是回
/// 100×60），所以是每一幀解出來立刻畫成小圖、原幀當場釋放
class GifFrames {
  GifFrames(this.images, this.endMs, this.loopMs);

  final List<ui.Image> images;

  /// 每一幀的結束毫秒（累計）
  final List<int> endMs;

  /// 一輪多長（毫秒）
  final int loopMs;

  int get bytes => images.fold(0, (s, im) => s + im.width * im.height * 4);

  void dispose() {
    for (final im in images) {
      im.dispose();
    }
    images.clear();
  }
}

/// 常駐幀的總位元組上限（64MB：一份 480p 五秒 12fps 的成品約 30MB，
/// 一般用法碰不到；15 秒 640p 才會被縮）
const kGifFrameBudget = 64 << 20;

/// 幀數上限：再多的成品（放慢四倍的 60 秒）預覽也不必每一幀都留
const kGifFrameCap = 400;

/// 這一幀該縮到多大：不超過預覽區、不放大、總量不超過預算。
/// 回傳（寬, 高）；[frames] 是要留的幀數
(int, int) gifFrameTarget({
  required int width,
  required int height,
  required int frames,
  required int maxWidth,
  required int maxHeight,
  int byteBudget = kGifFrameBudget,
}) {
  if (width <= 0 || height <= 0) return (1, 1);
  var scale = math.min(1.0, math.min(maxWidth / width, maxHeight / height));
  final n = math.max(1, frames);
  final need = n * (width * scale) * (height * scale) * 4;
  if (need > byteBudget) {
    scale = scale * math.sqrt(byteBudget / need);
  }
  return (
    math.max(1, (width * scale).round()),
    math.max(1, (height * scale).round()),
  );
}

/// 把 [ref]（檔案路徑或 `asset:` 參照）解成預覽幀。
/// [cancelled] 回 true 就中止（已解的全部釋放）並回 null；解不開也回 null
Future<GifFrames?> decodeGifFrames(
  String ref, {
  required int maxWidth,
  required int maxHeight,
  int maxFrames = kGifFrameCap,
  int byteBudget = kGifFrameBudget,
  bool Function()? cancelled,
}) async {
  ui.ImmutableBuffer? buf;
  ui.ImageDescriptor? desc;
  ui.Codec? codec;
  final frames = <ui.Image>[];
  void drop() {
    for (final im in frames) {
      im.dispose();
    }
    frames.clear();
  }

  try {
    Uint8List? bytes;
    if (GifStore.isAsset(ref)) {
      bytes = await GifStore.bytes(ref);
      if (bytes == null) return null;
      buf = await ui.ImmutableBuffer.fromUint8List(bytes);
    } else {
      // 檔案由引擎那邊直接讀，不經 Dart 堆（一份 GIF 幾 MB）
      buf = await ui.ImmutableBuffer.fromFilePath(ref);
    }
    int w, h;
    try {
      desc = await ui.ImageDescriptor.encoded(buf);
      w = desc.width;
      h = desc.height;
      codec = await desc.instantiateCodec();
    } catch (_) {
      // web 的算圖引擎沒有 ImageDescriptor：退回一般解碼，尺寸從第一幀拿
      bytes ??= await GifStore.bytes(ref);
      if (bytes == null) return null;
      codec = await ui.instantiateImageCodec(bytes);
      final first = await codec.getNextFrame();
      w = first.image.width;
      h = first.image.height;
      first.image.dispose();
      codec.dispose();
      codec = await ui.instantiateImageCodec(bytes);
    }
    if (w <= 0 || h <= 0) return null;
    final n = math.min(codec.frameCount, maxFrames);
    final (tw, th) = gifFrameTarget(
      width: w,
      height: h,
      frames: n,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      byteBudget: byteBudget,
    );
    final ends = <int>[];
    var acc = 0;
    for (var i = 0; i < n; i++) {
      final f = await codec.getNextFrame();
      if (cancelled?.call() == true) {
        f.image.dispose();
        drop();
        return null;
      }
      ui.Image img;
      if (tw == f.image.width && th == f.image.height) {
        img = f.image;
      } else {
        img = await _shrink(f.image, tw, th);
        f.image.dispose();
      }
      frames.add(img);
      final d = f.duration.inMilliseconds;
      // 0／太短的幀時長：瀏覽器的老規矩，當 100ms 播
      acc += d < 10 ? 100 : d;
      ends.add(acc);
    }
    if (cancelled?.call() == true) {
      drop();
      return null;
    }
    return GifFrames(frames, ends, acc);
  } catch (_) {
    drop();
    return null;
  } finally {
    codec?.dispose();
    desc?.dispose();
    buf?.dispose();
  }
}

Future<ui.Image> _shrink(ui.Image src, int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawImageRect(
    src,
    ui.Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final pic = rec.endRecording();
  try {
    return await pic.toImage(w, h);
  } finally {
    pic.dispose();
  }
}
