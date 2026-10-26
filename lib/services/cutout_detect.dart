import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import 'diagnostics.dart';

/// 照片裡找到的一個主體（人、寵物、物品）。[box] 是轉正後照片的
/// 0~1 座標、左上原點
class CutoutSubject {
  final int id;
  final Rect box;

  const CutoutSubject(this.id, this.box);
}

/// 一張照片的去背分析結果。
///
/// [mask] 是「全部主體」的遮罩（[w]×[h] 位元組，0＝背景、255＝主體），
/// 尺寸是轉正後、縮到分析上限的照片；[labels] 是每個像素屬於第幾個
/// 主體（0＝背景，[lw]×[lh]），點畫面切換主體用。只認得出人的時候
/// （iOS 16 以前、Android 沒有 Google Play 服務）[person] 為 true、
/// [subjects] 只有一個
class CutoutPhoto {
  final int w, h;
  final Uint8List mask;
  final Uint8List? labels;
  final int lw, lh;
  final List<CutoutSubject> subjects;
  final bool person;

  /// 原生端給的補充說明（例如：主體模型還在下載，先用人像）
  final String? note;

  const CutoutPhoto({
    required this.w,
    required this.h,
    required this.mask,
    required this.labels,
    required this.lw,
    required this.lh,
    required this.subjects,
    required this.person,
    this.note,
  });

  /// 照片座標（0~1）那一點是第幾個主體；背景回 0
  int subjectAt(double x, double y) {
    final l = labels;
    if (l == null || lw <= 0 || lh <= 0) {
      // 沒有標籤圖（只認人的那條路）：落在遮罩裡就算第一個
      final px = (x * w).floor().clamp(0, w - 1);
      final py = (y * h).floor().clamp(0, h - 1);
      return mask[py * w + px] >= 128 && subjects.isNotEmpty
          ? subjects.first.id
          : 0;
    }
    final px = (x * lw).floor().clamp(0, lw - 1);
    final py = (y * lh).floor().clamp(0, lh - 1);
    return l[py * lw + px];
  }
}

/// 一支影片的去背工作：可以叫停（見 [CutoutDetect.videoMask]）
class CutoutVideoJob {
  int? _token;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  Future<void> cancel() async {
    _cancelled = true;
    final t = _token;
    if (t == null) return;
    try {
      await CutoutDetect._ch.invokeMethod('cancel', {'token': t});
    } catch (_) {}
  }
}

/// 手機內建的去背：iOS 是系統的 Vision（iOS 17 起認得出任何主體，
/// 之前只認人）、Android 是 ML Kit（主體分割走 Google Play 服務、
/// 人像分割內建）。全部在手機上算，照片、影片不會離開裝置
class CutoutDetect {
  static const _ch = MethodChannel('markcut/cutout');

  static int _nextToken = 1;
  static final _progress = <int, void Function(double)>{};
  static bool _listening = false;

  static void _listen() {
    if (_listening) return;
    _listening = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'cutoutProgress' && call.arguments is Map) {
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

  /// 照片去背的保險絲代號（見 [Diag.fuseOn]）：開 App 時還在＝上一趟
  /// 算到一半 App 被關掉
  static const fuseKey = 'cutout';

  /// 最近一次失敗的原因（哪一步｜例外｜訊息）
  static String? lastError;

  static String? get lastErrorBrief {
    final s = lastError;
    if (s == null) return null;
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  /// 照片分析：找主體、出遮罩。[maxSide]＝分析的長邊上限。
  /// 做不了（web、通道不在、檔案讀不到）回 null
  static Future<CutoutPhoto?> analyzePhoto(
    String path, {
    int maxSide = 1600,
  }) async {
    if (kIsWeb || path.isEmpty) return null;
    lastError = null;
    await Diag.fuseOn(fuseKey, '自動去背');
    try {
      final r = await _ch.invokeMapMethod<String, Object?>('analyzePhoto', {
        'path': path,
        'maxSide': maxSide,
      });
      if (r == null) return null;
      final w = (r['w'] as num?)?.toInt() ?? 0;
      final h = (r['h'] as num?)?.toInt() ?? 0;
      final mask = r['mask'];
      if (w <= 0 || h <= 0 || mask is! Uint8List || mask.length != w * h) {
        lastError = '回傳的遮罩尺寸不對（$w×$h）';
        return null;
      }
      final lw = (r['lw'] as num?)?.toInt() ?? 0;
      final lh = (r['lh'] as num?)?.toInt() ?? 0;
      final labels = r['labels'];
      final subjects = <CutoutSubject>[];
      for (final e in (r['subjects'] as List?) ?? const []) {
        if (e is! Map) continue;
        double v(String k) => ((e[k] as num?) ?? 0).toDouble();
        final id = (e['id'] as num?)?.toInt();
        if (id == null || id <= 0) continue;
        subjects.add(
          CutoutSubject(id, Rect.fromLTWH(v('x'), v('y'), v('w'), v('h'))),
        );
      }
      if (Diag.fusePaused.containsKey(fuseKey)) {
        await Diag.fuseReset(fuseKey);
      }
      return CutoutPhoto(
        w: w,
        h: h,
        mask: mask,
        labels: labels is Uint8List && labels.length == lw * lh && lw > 0
            ? labels
            : null,
        lw: lw,
        lh: lh,
        subjects: subjects,
        person: r['kind'] == 'person',
        note: r['note'] as String?,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      Diag.ev('照片去背失敗：$lastError');
      return null;
    } finally {
      await Diag.fuseOff(fuseKey);
    }
  }

  /// 只留 [ids] 這幾個主體的遮罩，長邊不超過 [maxSide]（匯出要原尺寸
  /// 就給大一點）。回 (遮罩, 寬, 高)；做不了回 null
  static Future<(Uint8List, int, int)?> photoMask(
    String path,
    List<int> ids, {
    int maxSide = 4096,
  }) async {
    if (kIsWeb || path.isEmpty) return null;
    try {
      final r = await _ch.invokeMapMethod<String, Object?>('photoMask', {
        'path': path,
        'ids': ids,
        'maxSide': maxSide,
      });
      if (r == null) return null;
      final w = (r['w'] as num?)?.toInt() ?? 0;
      final h = (r['h'] as num?)?.toInt() ?? 0;
      final mask = r['mask'];
      if (w <= 0 || h <= 0 || mask is! Uint8List || mask.length != w * h) {
        return null;
      }
      return (mask, w, h);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      Diag.ev('照片去背遮罩失敗：$lastError');
      return null;
    }
  }

  /// 影片去背：整支影片每一格的人像遮罩寫進 [outPath]（.mcmk）。
  /// 成功回 true；做不了、被 [job] 叫停回 false（原因在 [lastError]）
  static Future<bool> videoMask(
    String path,
    String outPath, {
    void Function(double p)? onProgress,
    CutoutVideoJob? job,
  }) async {
    if (kIsWeb || path.isEmpty || (job?.cancelled ?? false)) return false;
    _listen();
    lastError = null;
    final token = _nextToken++;
    job?._token = token;
    if (onProgress != null) _progress[token] = onProgress;
    try {
      final r = await _ch.invokeMapMethod<String, Object?>('videoMask', {
        'path': path,
        'out': outPath,
        'token': token,
      });
      if (job?.cancelled ?? false) return false;
      final n = (r?['frames'] as num?)?.toInt() ?? 0;
      if (n <= 0) {
        lastError ??= '一格遮罩都沒算出來';
        return false;
      }
      return true;
    } on MissingPluginException {
      lastError = '這個平台不支援影片去背';
      return false;
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      Diag.ev('影片去背失敗：$lastError');
      return false;
    } finally {
      _progress.remove(token);
    }
  }
}
