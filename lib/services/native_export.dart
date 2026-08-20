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

  /// 這批檔案裡有沒有 HDR 影像軌（HLG/PQ）。
  /// 匯出頁用它決定要不要顯示「保留 HDR」開關；查不動（Android）回 false
  static Future<bool> anyHDR(List<String> paths) async {
    if (paths.isEmpty) return false;
    try {
      return await _ch.invokeMethod<bool>('hasHDR', paths) ?? false;
    } catch (_) {
      return false;
    }
  }

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
  /// 馬賽克／照片素材／子母畫面／調色現在都由 GPU 合成器
  ///（CIExportCompositor 的圖層模式）處理，不再退回 FFmpeg——
  /// 那條路解 4K HDR 要做軟體色調映射，一格 100MB，正是匯出閃退的
  /// 來源。倒轉在進到這裡之前就被預先渲染成「已倒好」的暫存檔
  ///（見 exportVideoToGallery），這裡的檢查只是保險
  static String? whyNot(ExportSpec spec) {
    final vids = <TimelineClip>[];
    for (final c in spec.clips) {
      if (spec.sources[c.sourceIndex].kind == ClipKind.video) vids.add(c);
      if (c.reverse) return '有倒轉的片段（前置處理漏了）';
      // 裁切／旋轉／透明度現在 CI 合成器都畫得出來（跟預覽同一套
      // 數學），不再退 FFmpeg——HDR 專案才走得到系統的色調映射
    }
    if (vids.isEmpty) return '沒有影片片段';
    // 順暢度也交給 Swift 端（videoComposition 的 frameDuration）
    return null;
  }

  /// 這份匯出需不需要圖層模式（多軌合成）。
  /// 需要的話 Swift 端會強制走 CI 合成器、開多條視訊軌
  static bool needsLayered(ExportSpec spec) {
    final vids = <TimelineClip>[];
    for (final c in spec.clips) {
      final kind = spec.sources[c.sourceIndex].kind;
      if (kind == ClipKind.image || kind == ClipKind.mosaic) return true;
      if (kind == ClipKind.video) {
        if (c.color.hasColor) return true;
        // 裁切/旋轉/透明度只有 CI 合成器（圖層模式）畫得出來
        if (c.cropped || c.rotated || c.faded) return true;
        vids.add(c);
      }
    }
    vids.sort((a, b) => a.offset.compareTo(b.offset));
    for (var i = 1; i < vids.length; i++) {
      if (vids[i].offset < vids[i - 1].end - 0.001) return true;
    }
    return false;
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
        'offset': c.offset,
        'track': c.track,
        'volume': c.volume.clamp(0.0, 1.0),
        'speed': c.speed,
        'fadeIn': c.fadeIn,
        'fadeOut': c.fadeOut,
        'scale': c.scale,
        'px': c.px,
        'py': c.py,
        'mirror': c.mirror,
        // 調色：預覽的 4x5 矩陣原封送過去，Swift 端在 gamma 域套同一顆
        'color': c.color.hasColor ? c.color.matrix : null,
        if (c.cropped) 'crop': [c.cropL, c.cropT, c.cropW, c.cropH],
        'rotation': c.rotation,
        'opacity': c.opacity,
      });
      cursor = c.end;
    }

    // 照片素材與馬賽克（圖層模式）。時間一律換算成輸出秒數——
    // 它們不進合成軌，整體變速不會自動套到它們身上
    final stills = <Map<String, dynamic>>[];
    final mosaics = <Map<String, dynamic>>[];
    for (final c in spec.clips) {
      final src = spec.sources[c.sourceIndex];
      if (src.kind == ClipKind.image) {
        stills.add({
          'path': src.path,
          'start': c.offset / sp,
          'end': c.end / sp,
          'track': c.track,
          'px': c.px,
          'py': c.py,
          'scale': c.scale,
          'mirror': c.mirror,
          'fadeIn': c.fadeIn / sp,
          'fadeOut': c.fadeOut / sp,
          'color': c.color.hasColor ? c.color.matrix : null,
          if (c.cropped) 'crop': [c.cropL, c.cropT, c.cropW, c.cropH],
          'rotation': c.rotation,
          'opacity': c.opacity,
        });
      } else if (src.kind == ClipKind.mosaic) {
        final ms = src.mosaicStyle ?? MosaicStyle();
        mosaics.add({
          'start': c.offset / sp,
          'end': c.end / sp,
          'track': c.track,
          'px': c.px,
          'py': c.py,
          'scale': c.scale,
          'type': ms.type,
          'strength': ms.strength,
          'color': ms.color,
          'feather': ms.feather,
        });
      }
    }
    // 馬賽克照軌道由下而上；Swift 端會照 z 交錯進圖層堆疊，
    // 只糊排在它下面的層（跟預覽、FFmpeg 同一套規則）
    mosaics.sort((a, b) => (a['track'] as int).compareTo(b['track'] as int));

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
        'layered': needsLayered(spec),
        // 順暢度（0＝跟預設一樣 30）
        'fps': spec.fps,
        // 保留 HDR（HEVC 10-bit HLG）
        'hdr': spec.hdr,
        'stills': stills,
        'mosaics': mosaics,
        'timelineDuration': spec.timelineDuration,
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
