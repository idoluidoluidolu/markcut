import 'dart:isolate';
import 'dart:typed_data';

/// 把 raw RGBA 像素包成一張 24 位元 BMP。
///
/// 為什麼要有這個：批次存 JPEG 時，原本的路是「toByteData(PNG)」
///（Skia 對整張 12MP 做 zlib，一張要好幾秒）→ 原生端把 PNG 解回
/// 點陣 → 再壓 JPEG。像素本來就在手上了，PNG 那一手純粹是白工。
/// BMP 沒有壓縮：包起來只是搬一次記憶體，原生端（ImageIO）解它
/// 也只是搬一次記憶體，之後照樣走同一個 JPEG 編碼器——
/// 輸出跟原本那條路的像素一模一樣，只是少做了一次 zlib 跟一次 inflate。
///
/// 用 24 位元、由下往上、BI_RGB：這是最古老、每個解碼器都認得的
/// BMP 長相（不碰 BITFIELDS、負高度那些「大多支援」的變體）。
/// rawRgba 是預乘 alpha；合成後的照片本來就是不透明的（有透明的
/// 來源照片在原本的 PNG→JPEG 路上也是被壓成黑底），所以直接丟 alpha
Uint8List rgbaToBmp24(Uint8List rgba, int width, int height) {
  if (rgba.length < width * height * 4) {
    throw ArgumentError('rgba 長度 ${rgba.length} 不夠 ${width}x$height');
  }
  final stride = (width * 3 + 3) & ~3; // 每列補到 4 的倍數
  const headers = 14 + 40;
  final size = headers + stride * height;
  final out = Uint8List(size);
  final bd = ByteData.view(out.buffer);
  // BITMAPFILEHEADER
  out[0] = 0x42; // 'B'
  out[1] = 0x4D; // 'M'
  bd.setUint32(2, size, Endian.little);
  bd.setUint32(10, headers, Endian.little);
  // BITMAPINFOHEADER
  bd.setUint32(14, 40, Endian.little);
  bd.setInt32(18, width, Endian.little);
  bd.setInt32(22, height, Endian.little); // 正值＝由下往上
  bd.setUint16(26, 1, Endian.little); // planes
  bd.setUint16(28, 24, Endian.little); // bpp
  bd.setUint32(30, 0, Endian.little); // BI_RGB
  bd.setUint32(34, stride * height, Endian.little);
  bd.setInt32(38, 2835, Endian.little); // 72 dpi
  bd.setInt32(42, 2835, Endian.little);

  for (var y = 0; y < height; y++) {
    var src = (height - 1 - y) * width * 4;
    var dst = headers + y * stride;
    for (var x = 0; x < width; x++) {
      out[dst] = rgba[src + 2]; // B
      out[dst + 1] = rgba[src + 1]; // G
      out[dst + 2] = rgba[src]; // R
      src += 4;
      dst += 3;
    }
  }
  return out;
}

/// 在另一個 isolate 裡做 [rgbaToBmp24]：12MP 是四千八百萬個位元組
/// 的迴圈，放主 isolate 會把進度視窗凍住一下。
/// 用 [TransferableTypedData] 搬進搬出，兩邊都不複製
Future<Uint8List> rgbaToBmp24InIsolate(
  Uint8List rgba,
  int width,
  int height,
) async {
  final carry = TransferableTypedData.fromList([rgba]);
  final back = await Isolate.run(() {
    final src = carry.materialize().asUint8List();
    return TransferableTypedData.fromList([rgbaToBmp24(src, width, height)]);
  });
  return back.materialize().asUint8List();
}
