import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import 'diagnostics.dart';

/// 把素材交給「平台自己的硬體管線」轉成工作檔：SDR、H.264、長邊有上限。
///
/// 為什麼要有這一層：iPhone 預設錄 4K HLG（HDR）。這種素材直接拿來用，
/// 每一環都很痛——
/// - 播放：一個片段一顆播放器，三段就是三顆 4K HDR 解碼器同時活著，
///   預熱時還會有兩顆在解，畫面就開始掉格；
/// - 匯出：FFmpeg 的色調映射是 32 位元浮點，一格 4K 的 gbrpf32le 就要
///   100MB，實測一支 4K HDR 素材的匯出峰值 1.7GB，iOS 直接把 App 收掉；
/// - 顏色：預覽走系統播放器（系統會轉），匯出走 FFmpeg（自己轉），
///   兩邊天生對不起來。
///
/// 轉成工作檔之後這三件事同時消失：解碼器只要解 1080p SDR、FFmpeg 再也
/// 看不到 HDR、預覽跟成品吃的是同一份素材。轉檔本身交給
/// AVAssetExportSession（iOS）與 Media3 Transformer（Android），
/// 都是硬體加速，而且色調映射是系統做的，跟系統播放器一致。
///
/// 原生端沒接上（web、舊版本、平台實作壞掉）時每個呼叫都回 null，
/// 呼叫端一律退回原檔——工作檔是加速，不是必要條件
class MediaPrep {
  static const _ch = MethodChannel('markcut/prep');

  static bool _wired = false;

  /// 每個轉檔工作的進度回呼，用 job 編號分開。
  ///
  /// 同時可以跑兩支：iPhone 的硬體編碼器吃得下，兩支一起跑的總時間
  /// 明顯比排隊短。再多就會互搶，而且記憶體跟著翻倍
  // 同時兩支硬體編碼在多素材匯入時會把 mediaserverd 打到重置
  // （實機 150：6 支素材壞了 5 支工作檔，只好退回 4K 原檔，
  // 關鍵幀疏＝滑動鈍）。匯入本來就有等待遮罩，慢一點換可靠
  static const _maxConcurrent = 1;
  static final Map<int, void Function(double)> _progressOf = {};
  static int _nextJob = 1;

  /// 目前在跑的工作數；滿了就排隊等
  static int _running = 0;
  static final List<Completer<void>> _waiting = [];

  static Future<void> _acquire() {
    if (_running < _maxConcurrent) {
      _running++;
      Diag.peak('同時轉檔（原生硬體）', _running);
      return Future.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    Diag.peak('轉檔排隊等硬體', _waiting.length);
    return c.future;
  }

  static void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
      return;
    }
    _running--;
  }

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'progress') {
        final a = call.arguments;
        if (a is Map) {
          final job = (a['job'] as num?)?.toInt();
          final v = (a['value'] as num?)?.toDouble();
          if (job != null && v != null) {
            _progressOf[job]?.call(v.clamp(0.0, 1.0));
          }
        }
      }
      // 原生端把失敗的真正原因送回來。以前只知道「失敗」，而失敗的素材
      // 會一路用 4K HDR 原檔播——那正是卡頓的來源，卻查不出為什麼
      if (call.method == 'note' && call.arguments is String) {
        Diag.note(call.arguments as String);
      }
      return null;
    });
  }

  /// 平台有沒有接這個通道（問一次就記住）
  static bool? _available;

  static Future<bool> get available async {
    if (_available != null) return _available!;
    try {
      _available = await _ch.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// 檢查一份影片檔實際長什麼樣：尺寸、編碼、位元率，還有**關鍵幀間隔**。
  ///
  /// 關鍵幀間隔是「左右滑動順不順」的決定性數字——seek 一定要從前一個
  /// 關鍵幀解過來，間隔 60 格就是每滑一下解 60 格。以前只能猜工作檔
  /// 有沒有生效，現在可以直接看檔案本身
  static Future<Map<String, dynamic>?> probe(String path) async {
    try {
      if (!await available) return null;
      return await _ch.invokeMapMethod<String, dynamic>('probe', path);
    } catch (_) {
      return null;
    }
  }

  /// [probe] 的輕量版：只讀容器層的中繼資料（尺寸/編碼/旋轉/SDR），
  /// 不掃關鍵幀——完整 probe 要把整支檔的取樣讀過一遍，幾 GB 的素材
  /// 光探測就要好幾秒。給「要不要蓋讀取遮罩」這種只看規格的判斷用。
  /// iOS（AVURLAsset）與 Android（MediaExtractor）都有實作、鍵一樣；
  /// 沒實作的平台回 null。
  /// 注意呼叫端拿 null 當「壞檔」的地方（編輯器的出廠檢驗）：Android
  /// 以前沒實作，每一支轉好的工作檔都因此被作廢——原生端沒接上時
  /// 這裡回 null 是「不知道」，不是「沒有畫面」
  static Future<Map<String, dynamic>?> probeLite(String path) async {
    try {
      if (!await available) return null;
      // 同一支檔匯入一趟會被問三次（接軌問長度、分類問 HDR、做代理
      // 前再問一次），每次原生端都重開 AVURLAsset 同步解析 4K 的
      // moov。檔案內容不變就不用再問：以「路徑＋大小＋修改時間」為
      // 鍵，內容換了自然不中（相簿暫存路徑會重複使用）
      final key = _liteKey(path);
      if (key != null) {
        final hit = _liteCache[key];
        if (hit != null) return Map<String, dynamic>.of(hit);
      }
      final m = await _ch.invokeMapMethod<String, dynamic>('probeLite', path);
      if (key != null && m != null && m['error'] == null) {
        if (_liteCache.length >= 64) _liteCache.remove(_liteCache.keys.first);
        _liteCache[key] = Map<String, dynamic>.of(m);
      }
      return m;
    } catch (_) {
      return null;
    }
  }

  static final Map<String, Map<String, dynamic>> _liteCache = {};

  static String? _liteKey(String path) {
    try {
      final st = File(path).statSync();
      if (st.type == FileSystemEntityType.notFound) return null;
      return '$path#${st.size}#${st.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return null;
    }
  }

  /// 測試用：清掉 [probeLite] 的快取
  @visibleForTesting
  static void resetProbeCacheForTest() => _liteCache.clear();

  /// [probe] 的結果排成一行人看得懂的字
  static String describe(Map<String, dynamic> m) {
    if (m['error'] != null) return '${m['path']}：${m['error']}';
    final b = StringBuffer('${m['path']}：');
    b.write('${m['w']}x${m['h']} ${m['codec'] ?? '?'}');
    final fps = (m['fps'] as num?)?.toDouble();
    if (fps != null && fps > 0) b.write(' ${fps.toStringAsFixed(0)}fps');
    b.write(' ${m['kbps'] ?? '?'}kbps');
    final mb = (m['sizeMb'] as num?)?.toDouble();
    if (mb != null) b.write(' ${mb.toStringAsFixed(1)}MB');
    if (m['rotated'] == true) b.write('（帶旋轉旗標）');
    final frames = (m['frames'] as num?)?.toInt();
    final keys = (m['keyframes'] as num?)?.toInt();
    final maxGop = (m['maxGopFrames'] as num?)?.toInt();
    if (frames != null && keys != null && keys > 0) {
      final avg = frames / keys;
      // 這一行就是結論：平均間隔幾格＝每滑一下要解幾格
      b.write('／關鍵幀每 ${avg.toStringAsFixed(1)} 格');
      if (maxGop != null) b.write('（最疏 $maxGop 格）');
      b.write(avg <= 8 ? ' ✓密' : ' ✗疏，滑動會鈍');
    }
    return b.toString();
  }

  /// 把 [src] 轉成工作檔寫到 [dest]。成功回 [dest]，失敗或平台不支援回 null。
  ///
  /// [maxShortSide] 是短邊上限（預設 1080＝直式 1080x1920、橫式
  /// 1920x1080）。解碼成本只有 4K 的四分之一，預覽綽綽有餘。
  /// [onProgress] 是 0~1
  static Future<String?> toWorkFile(
    String src,
    String dest, {
    int maxShortSide = 1080,
    // HDR 直通代理（HLG 10-bit，不做色調映射）——HDR 預覽模式用
    bool hdr = false,
    // Dart 端已經掃過整支檔、判定「不合規格、一定要轉」：原生端就別再
    // 掃一次（alreadyGoodEnough 會再把整支檔的關鍵幀數一遍，而它的
    // 條件比 Dart 端嚴，Dart 說不合它一定也說不合——長片白掃兩趟）
    bool prechecked = false,
    // 上一次用一般參數轉出來的檔不能用（原生端回報失敗、或轉好卻全黑／
    // 沒有視訊軌）：這一次叫原生端跳過第一段、直接走保守參數的退路
    //（Android：media3 預設編碼參數→720p；見 MainActivity.rungsFor）。
    // 同樣的參數再轉一次，多半只是再壞一次
    bool safe = false,
    void Function(double progress)? onProgress,
  }) async {
    if (!await available) return null;
    _wire();
    final job = _nextJob++;
    if (onProgress != null) _progressOf[job] = onProgress;
    await _acquire();
    try {
      return await _ch.invokeMethod<String>('toWorkFile', {
        'src': src,
        'dest': dest,
        'maxShortSide': maxShortSide,
        'job': job,
        if (hdr) 'hdr': true,
        if (prechecked) 'prechecked': true,
        if (safe) 'safe': true,
      });
    } catch (e) {
      // 原生呼叫本身炸掉（不是轉檔失敗回 null）：以前無聲吞掉，報告裡
      // 只剩「工作檔失敗」
      Diag.note('工作檔原生呼叫失敗：$e');
      return null;
    } finally {
      _progressOf.remove(job);
      _release();
    }
  }

  /// 取消正在進行的轉檔（使用者按了「先不要等」）
  static Future<void> cancel() async {
    try {
      await _ch.invokeMethod('cancel');
    } catch (_) {}
  }
}
