import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;

import 'diagnostics.dart';

/// 合成好的照片 → 原生編碼（iOS，通道 markcut/photo_save）。
///
/// 像素在 Dart 這邊本來就是 raw RGBA（[ui.Image.toByteData] rawRgba，
/// 預乘 alpha）。原生端用 CGDataProvider 直接在這塊記憶體上建 CGImage
///（不複製、不解碼），交給 CGImageDestination 出 JPEG 或 PNG——同一顆
/// ImageIO 編碼器，跟原本 flutter_image_compress 最後那步一樣。
/// 省掉的是：Dart 包 BMP（~100ms）、原生解 BMP＋整張重畫（UIImage
/// scaleWithMinWidth 就算比例 1 也會整張畫一遍）、PNG 那條 Skia zlib
///（12MP 一張 3.6~4.6 秒）。
///
/// 鐵律：這條路「不在」就當沒這回事——原生端還沒貼、Android、Web、
/// 通道任何一種失敗，[encodeRgba] 一律回 null，呼叫端走原本那條路。
/// 探測（probe）只做一次並快取：沒通道的時候別每張都把 48MB 送過去
/// 才發現沒人接。
class NativePhotoSave {
  static const channel = MethodChannel('markcut/photo_save');

  /// null＝還沒探過；之後就是探到的結果
  static bool? _available;

  /// 測試用：清掉探測快取
  @visibleForTesting
  static void debugReset() => _available = null;

  /// 這個平台有可能有這條路（只有 iOS 有原生端）
  static bool get platformEligible =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// 原生端在不在（一個 session 只問一次）
  static Future<bool> available() async {
    if (!platformEligible) return false;
    final known = _available;
    if (known != null) return known;
    try {
      final r = await channel.invokeMethod<bool>('probe');
      return _available = r == true;
    } on MissingPluginException {
      // 通道沒人接＝Swift 還沒貼進去
      return _available = false;
    } catch (e) {
      Diag.note('photo_save probe 失敗：$e');
      return _available = false;
    }
  }

  /// encodeRgba 的參數（純函式，測試釘住欄位）。
  /// [quality] 1~100，只有 JPEG 用
  static Map<String, Object?> encodeArgs({
    required Uint8List rgba,
    required int w,
    required int h,
    required bool jpeg,
    required int quality,
  }) => {
    'bytes': rgba,
    'w': w,
    'h': h,
    'jpeg': jpeg,
    'quality': quality.clamp(1, 100),
  };

  /// raw RGBA（預乘、w*h*4 位元組）→ JPEG 或 PNG 位元組。
  /// 任何原因做不到就回 null（呼叫端退回原本的路）
  static Future<Uint8List?> encodeRgba({
    required Uint8List rgba,
    required int w,
    required int h,
    required bool jpeg,
    int quality = 92,
  }) async {
    if (w <= 0 || h <= 0 || rgba.length < w * h * 4) return null;
    if (!await available()) return null;
    try {
      final out = await channel.invokeMethod<Uint8List>(
        'encodeRgba',
        encodeArgs(rgba: rgba, w: w, h: h, jpeg: jpeg, quality: quality),
      );
      if (out == null || out.isEmpty) return null;
      return out;
    } on MissingPluginException {
      _available = false;
      return null;
    } catch (e) {
      // 原生端回 FlutterError（尺寸不合、編碼失敗…）：這張退回舊路，
      // 下一張照樣先試原生（不是永久性的壞）
      Diag.note('photo_save encodeRgba 退回舊路：$e');
      return null;
    }
  }
}
