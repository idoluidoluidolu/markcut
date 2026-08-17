import 'dart:async';
import 'package:flutter/services.dart';

import '../models/timeline.dart';
import '../models/watermark_settings.dart';
import 'diagnostics.dart';
import 'video_processor.dart';

/// 用系統自己的管線匯出：AVComposition ＋ Core Animation 圖層 ＋
/// AVAssetExportSession。
///
/// 為什麼要換掉 FFmpeg：它的 HDR 色調映射是 32 位元浮點的軟體運算，一格
/// 4K 就要 100MB，實測峰值 1.7GB——那正是匯出閃退的來源。而且預覽走系統
/// 播放器、匯出走 FFmpeg，兩套引擎的顏色天生對不起來。
///
/// 換過來之後：記憶體由系統管、硬體編碼、而且匯出跟預覽是同一份合成，
/// 所見即所得不再是「盡量接近」。
///
/// 做不到的情況（見 [whyNot]）原樣退回 FFmpeg——這條路是加速，不是
/// 取代，任何一種舊功能都不能因此少掉
class NativeExport {
  static const _ch = MethodChannel('markcut/export');

  static bool _wired = false;
  static void Function(double)? _onProgress;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'progress' && call.arguments is num) {
        _onProgress?.call((call.arguments as num).toDouble().clamp(0.0, 1.0));
      }
      return null;
    });
  }

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

  /// 這份匯出能不能交給系統。回 null＝可以，回字串＝不行的理由。
  ///
  /// 條件嚴格是刻意的：系統的合成是「一條軌照順序播、圖層疊上去」的
  /// 模型。馬賽克要逐格重算像素、照片素材要當成靜態畫面軌、子母畫面
  /// 要同時疊兩層影片——這三種目前只有 FFmpeg 那條路做得到，硬塞的
  /// 結果是成品跟預覽不一樣，比慢更糟
  static String? whyNot(ExportSpec spec) {
    final vids = <TimelineClip>[];
    for (final c in spec.clips) {
      final kind = spec.sources[c.sourceIndex].kind;
      switch (kind) {
        case ClipKind.video:
          vids.add(c);
        case ClipKind.audio:
        case ClipKind.text:
        case ClipKind.wm:
          break;
        case ClipKind.image:
          return '有照片素材';
        case ClipKind.mosaic:
          return '有馬賽克';
      }
      if (c.reverse) return '有倒轉的片段';
    }
    if (vids.isEmpty) return '沒有影片片段';
    vids.sort((a, b) => a.offset.compareTo(b.offset));
    for (var i = 1; i < vids.length; i++) {
      if (vids[i].offset < vids[i - 1].end - 0.001) {
        return '同一時刻有兩層畫面（子母畫面）';
      }
    }
    return null;
  }

  /// 匯出到 [dest]。成功回 null，失敗回原因字串（取消回「已取消」）
  static Future<String?> run(
    ExportSpec spec,
    String dest, {
    void Function(double progress)? onProgress,
  }) async {
    _wire();
    _onProgress = onProgress;
    final sp = spec.speed <= 0 ? 1.0 : spec.speed;

    // 影片片段：照時間排好，gap 是跟前一段之間的空白
    final vids = [
      for (final c in spec.clips)
        if (spec.sources[c.sourceIndex].kind == ClipKind.video) c,
    ]..sort((a, b) => a.offset.compareTo(b.offset));
    var cursor = 0.0;
    final clips = <Map<String, dynamic>>[];
    for (final c in vids) {
      clips.add({
        'path': spec.sources[c.sourceIndex].path,
        'start': c.trimStart,
        'end': c.trimEnd,
        'gap': (c.offset - cursor).clamp(0.0, 1e6),
        'volume': c.volume.clamp(0.0, 1.0),
        'speed': c.speed,
        'fadeIn': c.fadeIn,
        'fadeOut': c.fadeOut,
        'scale': c.scale,
        'px': c.px,
        'py': c.py,
        'mirror': c.mirror,
      });
      cursor = c.end;
    }

    // 純聲音素材（配樂）：可以跟影片重疊，位置照時間軸絕對秒數
    final audios = [
      for (final c in spec.clips)
        if (spec.sources[c.sourceIndex].kind == ClipKind.audio)
          {
            'path': spec.sources[c.sourceIndex].path,
            'start': c.trimStart,
            'end': c.trimEnd,
            'offset': c.offset,
            'volume': c.volume.clamp(0.0, 1.0),
            'speed': c.speed,
            'fadeIn': c.fadeIn,
            'fadeOut': c.fadeOut,
          },
    ];

    // 疊在畫面上的整版 PNG。時間一律換算成「輸出秒數」（除以整體速度），
    // 圖層動畫是照輸出時間跑的
    final overlays = <Map<String, dynamic>>[];
    for (final c in spec.clips) {
      final png = spec.overlayPngs[c.id];
      if (png == null) continue;
      overlays.add({
        'png': png,
        'start': c.offset / sp,
        'end': c.end / sp,
        'anim': 'none',
      });
    }
    final wm = spec.watermarkPng;
    if (wm != null) {
      overlays.add({
        'png': wm,
        'start': spec.wmStart / sp,
        'end': spec.wmEnd / sp,
        'anim': switch (spec.wmAnimation) {
          WmAnimation.none => 'none',
          WmAnimation.blink => 'blink',
          WmAnimation.drift => 'drift',
          WmAnimation.marquee => 'marquee',
        },
        // 動畫週期是「時間軸秒」，輸出時間要換算回去
        'cycle': spec.wmCycle / sp,
        'on': spec.wmOn / sp,
        'animSpeed': spec.wmSpeed * sp,
        'range': spec.wmRange,
      });
    }

    try {
      final err = await _ch.invokeMethod<String>('run', {
        'clips': clips,
        'audios': audios,
        'overlays': [
          for (final o in overlays)
            {...o, 'png': Uint8List.fromList(o['png'] as Uint8List)},
        ],
        'outW': spec.outW,
        'outH': spec.outH,
        'speed': sp,
        'dest': dest,
        'ci': Diag.ciExport.value,
      });
      if (err != null) Diag.note('原生匯出失敗：$err');
      return err;
    } catch (e) {
      Diag.note('原生匯出叫不動：$e');
      return '$e';
    } finally {
      _onProgress = null;
    }
  }

  static Future<void> cancel() async {
    try {
      await _ch.invokeMethod('cancel');
    } catch (_) {}
  }
}
