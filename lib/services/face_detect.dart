import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../models/mosaic.dart';
import 'diagnostics.dart';

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

/// 影片的某一格（素材秒數）偵測到的臉。框是轉正後的畫面座標（0~1、左上原點）
class FaceSample {
  final double t;
  final List<FaceBox> faces;

  const FaceSample(this.t, this.faces);
}

/// 一支影片的找臉工作：可以叫停（見 [FaceDetect.inVideo]）
class FaceVideoJob {
  int? _token;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  /// 叫原生端停下來。之後 inVideo 回 null（叫停的人自己知道為什麼）
  Future<void> cancel() async {
    _cancelled = true;
    final t = _token;
    if (t == null) return;
    try {
      await FaceDetect._ch.invokeMethod('cancelVideo', {'token': t});
    } catch (_) {}
  }
}

/// 手機內建的人臉偵測：iOS 是系統的 Vision、Android 是 ML Kit。
/// 全部在手機上算，照片、影片不會離開裝置
class FaceDetect {
  static const _ch = MethodChannel('markcut/face');

  static int _nextToken = 1;

  /// 進行中的影片：token → 進度回呼（原生端送 videoProgress 過來）
  static final _progress = <int, void Function(double)>{};
  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'videoProgress' && call.arguments is Map) {
        final a = call.arguments as Map;
        final token = (a['token'] as num?)?.toInt();
        final p = (a['p'] as num?)?.toDouble();
        if (token != null && p != null) {
          _progress[token]?.call(p.clamp(0.0, 1.0));
        }
      }
      return null;
    });
  }

  /// 影片每 1/[fps] 秒取一格找臉（時間是素材秒數）。偵測不了（web、
  /// 通道不在、檔案讀不到）或被 [job] 叫停回 null
  static Future<List<FaceSample>?> inVideo(
    String path, {
    double fps = 10,
    void Function(double p)? onProgress,
    FaceVideoJob? job,
  }) async {
    if (kIsWeb || path.isEmpty || (job?.cancelled ?? false)) return null;
    _listen();
    final token = _nextToken++;
    job?._token = token;
    if (onProgress != null) _progress[token] = onProgress;
    try {
      final r = await _ch.invokeMethod<List<Object?>>('analyzeVideo', {
        'path': path,
        'token': token,
        'fps': fps,
      });
      if (r == null || (job?.cancelled ?? false)) return null;
      final out = <FaceSample>[];
      for (final e in r) {
        if (e is! Map) continue;
        final t = (e['t'] as num?)?.toDouble();
        if (t == null) continue;
        final faces = <FaceBox>[];
        for (final f in (e['f'] as List?) ?? const []) {
          if (f is! List || f.length < 4) continue;
          final b = FaceBox.fromMap({
            'x': f[0],
            'y': f[1],
            'w': f[2],
            'h': f[3],
          });
          if (b != null) faces.add(b);
        }
        out.add(FaceSample(t, faces));
      }
      return out;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } finally {
      _progress.remove(token);
    }
  }

  /// 照片找臉的保險絲代號（見 [Diag.fuseOn]）：在 [Diag.fusePaused] 裡＝
  /// 上一趟找到一半 App 被關掉，先別自動找
  static const fuseKey = 'face';

  /// 最近一次照片找臉，原生那邊回的失敗原因（例外類別＋訊息）；
  /// 檔案讀不到、成功都是 null
  static String? lastError;

  /// 照片裡的臉。偵測不了（web、通道不在、檔案讀不到）回 null；
  /// 偵測成功但沒有臉回空清單——兩者呼叫端要分開講
  static Future<List<FaceBox>?> inPhoto(String path) async {
    if (kIsWeb || path.isEmpty) return null;
    lastError = null;
    await Diag.fuseOn(fuseKey, '自動找臉');
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
      if (Diag.fusePaused.containsKey(fuseKey)) {
        await Diag.fuseReset(fuseKey);
      }
      return out;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      Diag.ev('照片找臉失敗：$lastError');
      return null;
    } finally {
      await Diag.fuseOff(fuseKey);
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
