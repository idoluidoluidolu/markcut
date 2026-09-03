import 'dart:typed_data';

/// 直接讀 PNG 檔頭（IHDR）拿像素尺寸，不解圖。
///
/// 給 flutter_image_compress 用：它的 minWidth/minHeight 預設 1920/1080，
/// iOS 端把它當「上限」——不給的話比它大的圖會先縮到 1920 才壓 JPEG，
/// 12MP 的照片就這樣變成 2.7MP 出去。合成出來的永遠是 PNG，
/// 寬高就在固定位置，再解一次 12MP 的圖只為了拿尺寸太浪費。
///
/// 不是 PNG（簽名不對、太短）回 null
(int w, int h)? pngSize(Uint8List b) {
  if (b.length < 24) return null;
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < sig.length; i++) {
    if (b[i] != sig[i]) return null;
  }
  // 8 位元組簽名 + 4 長度 + 4 "IHDR" → 寬在 16、高在 20，大端序
  if (b[12] != 0x49 || b[13] != 0x48 || b[14] != 0x44 || b[15] != 0x52) {
    return null;
  }
  final d = ByteData.sublistView(b, 16, 24);
  final w = d.getUint32(0);
  final h = d.getUint32(4);
  if (w == 0 || h == 0) return null;
  return (w, h);
}
