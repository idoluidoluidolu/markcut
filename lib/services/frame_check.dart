import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// 兩張圖的平均色差（每像素 RGB 絕對差的平均，0~255）。
/// 兩張都縮到 32 寬再比：HDR 還原跑掉（沖淡過曝）是整片的差異，
/// 縮圖就看得出來；壓縮造成的細節差則會被平均掉。
/// 解不開回 null
Future<double?> frameColorDiff(Uint8List a, Uint8List b) async {
  Future<ByteData?> raw(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 32,
        targetHeight: 32,
      );
      final f = await codec.getNextFrame();
      final d = await f.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      f.image.dispose();
      codec.dispose();
      return d;
    } catch (_) {
      return null;
    }
  }

  final da = await raw(a);
  final db = await raw(b);
  if (da == null || db == null) return null;
  final ba = da.buffer.asUint8List();
  final bb = db.buffer.asUint8List();
  final n = math.min(ba.length, bb.length);
  if (n < 4) return null;
  var sum = 0.0;
  var cnt = 0;
  for (var i = 0; i + 3 < n; i += 4) {
    sum +=
        ((ba[i] - bb[i]).abs() +
            (ba[i + 1] - bb[i + 1]).abs() +
            (ba[i + 2] - bb[i + 2]).abs()) /
        3.0;
    cnt++;
  }
  return cnt == 0 ? null : sum / cnt;
}

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
