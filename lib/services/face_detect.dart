import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../models/mosaic.dart';

/// 一張臉的框：轉正後的照片座標，0~1、左上原點
class FaceBox {
  final double x, y, w, h;

  const FaceBox(this.x, this.y, this.w, this.h);

  /// 原生端回來的一筆。超出照片的部分夾掉；太小（不到 0.4%）的
  /// 多半是誤判（衣服花紋、背景的圖案），丟掉
  static FaceBox? fromMap(Map<Object?, Object?> m) {
    double v(String k) => ((m[k] as num?) ?? 0).toDouble();
    final l = v('x').clamp(0.0, 1.0);
    final t = v('y').clamp(0.0, 1.0);
    final r = (v('x') + v('w')).clamp(0.0, 1.0);
    final b = (v('y') + v('h')).clamp(0.0, 1.0);
    if (r - l < 0.004 || b - t < 0.004) return null;
    return FaceBox(l, t, r - l, b - t);
  }
}

/// 手機內建的人臉偵測：iOS 是系統的 Vision、Android 是 ML Kit。
/// 全部在手機上算，照片不會離開裝置
class FaceDetect {
  static const _ch = MethodChannel('markcut/face');

  /// 照片裡的臉。偵測不了（web、通道不在、檔案讀不到）回 null；
  /// 偵測成功但沒有臉回空清單——兩者呼叫端要分開講
  static Future<List<FaceBox>?> inPhoto(String path) async {
    if (kIsWeb || path.isEmpty) return null;
    try {
      final r = await _ch.invokeMethod<List<Object?>>('detectImage', {
        'path': path,
      });
      if (r == null) return null;
      final out = <FaceBox>[];
      for (final e in r) {
        final f = e is Map ? FaceBox.fromMap(e) : null;
        if (f != null) out.add(f);
      }
      return out;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// 偵測到的臉 → 一塊蓋臉的橢圓馬賽克（[w]×[h]＝照片的像素尺寸，
/// 只用來換算比例）。偵測框大約是眉毛到下巴，往外放一圈、往上挪
/// 一點，額頭跟頭髮邊才蓋得到
PhotoMosaic faceMosaic(
  FaceBox f,
  double w,
  double h, {
  required MosaicStyle style,
  bool oval = true,
}) {
  final wPx = f.w * w * 1.3;
  final hPx = f.h * h * 1.45;
  return PhotoMosaic(
    x: (f.x + f.w / 2).clamp(0.0, 1.0),
    y: (f.y + f.h / 2 - f.h * 0.08).clamp(0.0, 1.0),
    scale: (wPx / (w < h ? w : h)).clamp(0.02, 3.0),
    aspect: (hPx / wPx).clamp(0.2, 5.0),
    style: style.copy(),
    oval: oval,
    face: true,
  );
}
