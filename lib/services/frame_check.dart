import 'dart:typed_data';
import 'dart:ui' as ui;

/// 一張圖（JPEG/PNG bytes）的平均亮度（0~255）。解不開回 null。
///
/// 縮到 64 寬再抽樣：這是拿來判斷「這張是不是全黑」的，
/// 不需要整張算——一格 1080p 全算要幾十毫秒，而它會跑在匯入的路上
Future<double?> meanLuminance(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;
    final b = data.buffer.asUint8List();
    var sum = 0.0;
    var n = 0;
    for (var i = 0; i + 3 < b.length; i += 16) {
      sum += 0.299 * b[i] + 0.587 * b[i + 1] + 0.114 * b[i + 2];
      n++;
    }
    return n == 0 ? null : sum / n;
  } catch (_) {
    return null;
  }
}
