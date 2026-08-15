import 'dart:async';

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
  static void Function(double)? _onProgress;

  /// 一次只轉一支。兩個硬體轉檔工作同時跑會互相搶解碼器，
  /// 加起來反而比排隊慢，記憶體也翻倍
  static Future<void> _queue = Future.value();

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'progress' && call.arguments is num) {
        _onProgress?.call((call.arguments as num).toDouble().clamp(0.0, 1.0));
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

  /// 把 [src] 轉成工作檔寫到 [dest]。成功回 [dest]，失敗或平台不支援回 null。
  ///
  /// [maxShortSide] 是短邊上限（預設 1080＝直式 1080x1920、橫式
  /// 1920x1080）。解碼成本只有 4K 的四分之一，預覽綽綽有餘。
  /// [onProgress] 是 0~1
  static Future<String?> toWorkFile(
    String src,
    String dest, {
    int maxShortSide = 1080,
    void Function(double progress)? onProgress,
  }) {
    final job = _queue.then((_) async {
      if (!await available) return null;
      _wire();
      _onProgress = onProgress;
      try {
        return await _ch.invokeMethod<String>('toWorkFile', {
          'src': src,
          'dest': dest,
          'maxShortSide': maxShortSide,
        });
      } catch (_) {
        return null;
      } finally {
        _onProgress = null;
      }
    });
    // 排隊用的 future 不能帶錯誤，不然一次失敗會把後面全部毒死
    _queue = job.then((_) {}, onError: (_) {});
    return job;
  }

  /// 取消正在進行的轉檔（使用者按了「先不要等」）
  static Future<void> cancel() async {
    try {
      await _ch.invokeMethod('cancel');
    } catch (_) {}
  }
}
