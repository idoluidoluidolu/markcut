import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../models/watermark_settings.dart';
import 'diagnostics.dart';
// 暫存檔刪除拆成平台檔：這支服務要能在 Web 編譯（呼叫端是共用畫面）
import 'hdr_photo_temp_io.dart'
    if (dart.library.js_interop) 'hdr_photo_temp_web.dart';
import 'watermark_renderer.dart';
import 'batch_overlay_cache.dart';

/// HDR 照片的批次匯出（iOS 17+，原生端 markcut/photo 通道）。
///
/// 現在的照片路是 dart:ui 解碼→合成→PNG/JPEG：第一步就是 8-bit SDR，
/// iPhone 的 HDR 照片（帶增益圖的 HEIC/JPEG）出來一律是平的。
/// 這條路把「來源是 HDR」的照片交給原生：CoreImage 展開成 HDR、
/// 黑底畫布置中、疊上 **同一份** 整版浮水印 PNG（[WatermarkRenderer]
/// 的 renderOverlayPng，預覽與影片匯出畫的就是它），寫成 10-bit HEIC
///（Rec.2100 HLG）——相簿會當 HDR 顯示。
///
/// 三條鐵律：
/// - 不是 HDR 的來源、iOS < 17、Web/Android：[probe] 回 hdr=false，
///   呼叫端照走原本那條 SDR 路，一個位元都不改
/// - 原生失敗（任何原因）回字串，呼叫端一樣退回 SDR 路
/// - 浮水印停在 SDR 基準白（overlayGain 1）；字底下的畫面先夾回 1.0
///   再混色，跟影片的 HDR 合成器同一套數學
class HdrPhotoExport {
  static const _ch = MethodChannel('markcut/photo');

  /// 這個平台有這條路嗎（只有 iOS 有原生端；版本夠不夠由 probe 回答）
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// 測試用：換掉「存到相簿」那一步（gal 在測試裡沒有平台端）
  @visibleForTesting
  static Future<void> Function(String path, String album)? debugSaver;

  /// 測試用：換掉暫存目錄（path_provider 在測試裡沒有平台端）
  @visibleForTesting
  static Future<String> Function()? debugTempDir;

  /// 讀檔頭：轉正後的尺寸＋要不要走 HDR 路。查不到／平台不支援回 null
  static Future<HdrPhotoProbe?> probe(String path) async {
    if (!supported) return null;
    try {
      final m = await _ch.invokeMethod<Map>('probe', path);
      if (m == null) return null;
      return HdrPhotoProbe(
        hdr: m['hdr'] == true,
        w: (m['w'] as num?)?.toInt() ?? 0,
        h: (m['h'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  /// 原生 export 的參數（純函式，測試釘住欄位）。
  /// [quality] 是 0~100（跟 JPEG 畫質同一個數字），原生吃 0~1
  static Map<String, Object?> exportArgs({
    required String src,
    required String dest,
    required PhotoCanvasGeometry geo,
    required Uint8List? overlay,
    int quality = 92,
    double overlayGain = 1.0,
  }) => {
    'src': src,
    'dest': dest,
    'outW': geo.canvasW,
    'outH': geo.canvasH,
    'photoX': geo.photoX,
    'photoY': geo.photoY,
    'overlay': ?overlay,
    'overlayGain': overlayGain,
    'quality': quality.clamp(1, 100) / 100.0,
  };

  /// 匯一張 HDR 照片到相簿。成功回 null，失敗回原因（呼叫端退 SDR 路）。
  ///
  /// [probe] 要是 [HdrPhotoExport.probe] 的結果而且 hdr 為 true；
  /// [canvasAspect] 跟 renderPhotoComposite 的同名參數同義（null＝跟照片一樣）
  static Future<String?> exportToGallery({
    required String srcPath,
    required HdrPhotoProbe probe,
    required WatermarkSettings settings,
    double? canvasAspect,
    int quality = 92,
    double overlayGain = 1.0,
    String album = '浮水印',
    String? name,
    BatchOverlayCache? overlayCache,
  }) async {
    if (!probe.hdr) return '來源不是 HDR';
    if (probe.w < 2 || probe.h < 2) return '照片尺寸探不到';
    final geo = photoCanvasGeometry(probe.w, probe.h, canvasAspect);
    Uint8List? overlay;
    if (settings.hasAnyMark) {
      Future<Uint8List> render() => WatermarkRenderer.renderOverlayPng(
        settings,
        geo.canvasW,
        geo.canvasH,
      );
      overlay = overlayCache == null
          ? await render()
          : await overlayCache.get(
              '${geo.canvasW}|${geo.canvasH}|${jsonEncode(settings.toJson())}',
              render,
            );
    }
    final dir =
        await (debugTempDir?.call() ??
            getTemporaryDirectory().then((d) => d.path));
    final fname =
        name ?? 'watermarker_${DateTime.now().millisecondsSinceEpoch}';
    final dest = '$dir/$fname.heic';
    String? err;
    try {
      err = await _ch.invokeMethod<String>(
        'export',
        exportArgs(
          src: srcPath,
          dest: dest,
          geo: geo,
          overlay: overlay,
          quality: quality,
          overlayGain: overlayGain,
        ),
      );
    } catch (e) {
      err = '$e';
    }
    if (err != null) {
      Diag.note('HDR 照片匯出退回 SDR：$err');
      return err;
    }
    try {
      final save = debugSaver ?? _saveToGallery;
      await save(dest, album);
    } catch (e) {
      Diag.note('HDR 照片存相簿失敗：$e');
      return '存到相簿失敗：$e';
    } finally {
      deletePhotoTemp(dest);
    }
    return null;
  }

  static Future<void> _saveToGallery(String path, String album) async {
    if (!await Gal.hasAccess(toAlbum: true)) {
      final ok = await Gal.requestAccess(toAlbum: true);
      if (!ok) throw StateError('沒有相簿存取權限');
    }
    // 走「檔案路徑」那個存法：相簿會原封收下 HEIC（含 10-bit／HLG 標記）；
    // putImageBytes 也是原封，但原生端會照 name 命名、副檔名對不上
    await Gal.putImage(path, album: album);
  }
}

/// 檔頭探測結果
class HdrPhotoProbe {
  const HdrPhotoProbe({required this.hdr, required this.w, required this.h});

  /// 來源是 HDR、而且這台匯得出（iOS 17+）
  final bool hdr;

  /// 轉正後的像素尺寸（跟 dart:ui 解出來的一樣）
  final int w;
  final int h;
}

/// 照片在畫布上的幾何：畫布尺寸＋照片左上角的位置（畫布像素、左上原點）。
/// 整數數學跟 [WatermarkRenderer.renderPhotoComposite] 一字不差——
/// 原生端拿這份定位，成品的黑邊與浮水印座標才跟 SDR 路、跟預覽對得上
class PhotoCanvasGeometry {
  const PhotoCanvasGeometry({
    required this.photoW,
    required this.photoH,
    required this.canvasW,
    required this.canvasH,
    required this.photoX,
    required this.photoY,
  });

  final int photoW;
  final int photoH;
  final int canvasW;
  final int canvasH;
  final double photoX;
  final double photoY;

  /// 沒補邊（畫布＝照片）
  bool get identity => canvasW == photoW && canvasH == photoH;
}

/// 跟 renderPhotoComposite 同一段判斷：比例差 0.001 以內＝不補邊；
/// 補邊時照片一邊貼滿、另一邊補黑，像素不縮水，置中的位移是 (差/2)
///（可以是 .5，跟 Dart 那邊一樣不四捨五入）
PhotoCanvasGeometry photoCanvasGeometry(int w, int h, double? canvasAspect) {
  if (canvasAspect == null ||
      w <= 0 ||
      h <= 0 ||
      (canvasAspect - w / h).abs() <= 0.001) {
    return PhotoCanvasGeometry(
      photoW: w,
      photoH: h,
      canvasW: w,
      canvasH: h,
      photoX: 0,
      photoY: 0,
    );
  }
  final int cw, ch;
  if (canvasAspect >= w / h) {
    ch = h;
    cw = (h * canvasAspect).round();
  } else {
    cw = w;
    ch = (w / canvasAspect).round();
  }
  return PhotoCanvasGeometry(
    photoW: w,
    photoH: h,
    canvasW: cw,
    canvasH: ch,
    photoX: (cw - w) / 2,
    photoY: (ch - h) / 2,
  );
}
