import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'bmp_wrap.dart';
import 'native_photo_save.dart';
import 'photo_saver.dart';

/// 合成好的 [ui.Image] 怎麼變成檔案。批次與單張匯出共用這一條，
/// 兩邊的輸出才會一模一樣（以前單張還在走「PNG 再重壓 JPEG」的舊路）。
///
/// 依序試，哪條先成功就用哪條：
/// 1. 原生（iOS、Swift 已貼）：raw RGBA 直接交給 ImageIO 出 JPEG/PNG
/// 2. JPEG 舊快路：raw RGBA 包 BMP（isolate）→ flutter_image_compress
/// 3. PNG：Skia toByteData(png)；要 JPEG 的話再試一次 compress，
///    轉不了就照樣給 PNG（總比失敗好）
class PhotoEncoded {
  const PhotoEncoded(this.bytes, this.ext, this.via);

  final Uint8List bytes;

  /// 'jpg' 或 'png'（要 JPEG 但這台轉不了時會是 'png'）
  final String ext;

  /// 走了哪條路：'native' / 'bmp' / 'png' / 'png->jpeg'（診斷與測試用）
  final String via;
}

/// 編碼（不 dispose [image]，呼叫端自己收）
Future<PhotoEncoded> encodePhotoImage(
  ui.Image image, {
  required bool jpeg,
  int quality = 92,
}) async {
  final w = image.width, h = image.height;
  // raw 只拿一次：原生路跟 BMP 路都吃它
  ByteData? raw;
  if (!kIsWeb) {
    try {
      raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } catch (_) {
      raw = null;
    }
  }
  final rgba = raw?.buffer.asUint8List();

  // 1. 原生
  if (rgba != null) {
    final out = await NativePhotoSave.encodeRgba(
      rgba: rgba,
      w: w,
      h: h,
      jpeg: jpeg,
      quality: quality,
    );
    if (out != null) return PhotoEncoded(out, jpeg ? 'jpg' : 'png', 'native');
  }

  // 2. JPEG：BMP 快路
  if (jpeg && rgba != null) {
    try {
      final bmp = await rgbaToBmp24InIsolate(rgba, w, h);
      final j = await FlutterImageCompress.compressWithList(
        bmp,
        // 一定要給：預設 1920x1080 在 iOS 是「上限」，比它大的圖
        // 會被縮到 1920 才壓——12MP 的照片就這樣變成 2.7MP 出去
        minWidth: w,
        minHeight: h,
        quality: quality,
        format: CompressFormat.jpeg,
      );
      if (j.isNotEmpty) return PhotoEncoded(j, 'jpg', 'bmp');
    } catch (_) {
      // 退回 PNG 路
    }
  }

  // 3. PNG（無損；要 JPEG 再試一次重壓）
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  if (png == null) throw StateError('toByteData(png) 回 null');
  final pngBytes = png.buffer.asUint8List();
  if (jpeg) {
    try {
      final j = await FlutterImageCompress.compressWithList(
        pngBytes,
        minWidth: w,
        minHeight: h,
        quality: quality,
        format: CompressFormat.jpeg,
      );
      if (j.isNotEmpty) return PhotoEncoded(j, 'jpg', 'png->jpeg');
    } catch (_) {
      // 這台轉不了 JPEG 就照樣給 PNG
    }
  }
  return PhotoEncoded(pngBytes, 'png', 'png');
}

/// 編碼＋存相簿（手機）／下載（Web）。回 (給使用者看的訊息, 實際副檔名)。
/// 不 dispose [image]；會丟例外（權限以外的失敗），呼叫端自己接
Future<(String, String)> savePhotoImage(
  ui.Image image, {
  required bool jpeg,
  required String name,
  int quality = 92,
}) async {
  final enc = await encodePhotoImage(image, jpeg: jpeg, quality: quality);
  final msg = await savePhotoPng(enc.bytes, name, ext: enc.ext);
  return (msg, enc.ext);
}
