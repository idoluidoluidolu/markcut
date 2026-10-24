import 'dart:math' as math;

import '../models/timeline.dart';
import 'face_tracks.dart';

/// 一個人的軌跡要變成時間軸上的哪一塊馬賽克
class FaceMosaicPlan {
  /// 放在時間軸的哪裡（秒，原速）
  final double offset;
  final double length;

  /// 會動的馬賽克關鍵點（見 MediaSource.mosaicPath）：s 從 0 起算，
  /// 位置大小是畫布 0~1，大小已經一段一段併好（quantizeMosaicPath）
  final List<double> path;

  /// 頭像用的那一格：影片素材的秒數＋轉正後的框（0~1）
  final FaceKey best;

  const FaceMosaicPlan(this.offset, this.length, this.path, this.best);
}

/// 影片片段畫在畫布上的框（畫布 0~1）：先等比塞進畫布（跟匯出的
/// layerBox 同一個算式），再乘片段的縮放、擺在 px/py
({double left, double top, double w, double h}) videoBoxOnCanvas(
  TimelineClip c,
  double srcAspect,
  double canvasAspect,
) {
  // 以畫布高＝1、寬＝canvasAspect 的單位算，最後再換回 0~1
  double fitW, fitH;
  if (srcAspect >= canvasAspect) {
    fitW = canvasAspect;
    fitH = fitW / srcAspect;
  } else {
    fitH = 1;
    fitW = srcAspect;
  }
  final bw = fitW * c.scale, bh = fitH * c.scale;
  final left = c.px * canvasAspect - bw / 2;
  final top = c.py - bh / 2;
  return (left: left / canvasAspect, top: top, w: bw / canvasAspect, h: bh);
}

/// 每個人的軌跡（影片素材秒數、轉正後的畫面 0~1）→ 時間軸上一塊會動的
/// 馬賽克。照片段目前的擺法換算：等比塞進畫布、縮放、位置、鏡像、旋轉
///（轉了角度就用轉完的外框，寧可多蓋）。裁切不管——裁掉的地方本來就
/// 看不到，碼在上面也看不出來。
///
/// 只留影片片段實際播得到的那一段；整段都不在片段裡的人丟掉
List<FaceMosaicPlan> planFaceMosaics(
  List<FaceTrack> tracks,
  TimelineClip video,
  double srcAspect,
  double canvasAspect,
) {
  final box = videoBoxOnCanvas(video, srcAspect, canvasAspect);
  final sp = video.speed.clamp(0.1, 16.0);
  final rad = video.rotation * math.pi / 180;
  final cosA = math.cos(rad), sinA = math.sin(rad);
  // 片段中心（畫布 0~1）；旋轉以它為軸
  final ccx = box.left + box.w / 2, ccy = box.top + box.h / 2;

  final out = <FaceMosaicPlan>[];
  for (final tr in tracks) {
    final pts = <(double, double, double, double, double)>[];
    for (final k in tr.keys) {
      if (k.t < video.trimStart - 1e-6 || k.t > video.trimEnd + 1e-6) continue;
      final t = video.reverse
          ? video.offset + (video.trimEnd - k.t) / sp
          : video.offset + (k.t - video.trimStart) / sp;
      // 轉正後的畫面 0~1 → 畫布 0~1（鏡像是左右翻）
      final fx = video.mirror ? 1 - k.cx : k.cx;
      var cx = box.left + fx * box.w;
      var cy = box.top + k.cy * box.h;
      var w = k.w * box.w;
      var h = k.h * box.h;
      if (video.rotation.abs() > 0.01) {
        // 中心繞片段中心轉（換成同一個比例尺再轉，畫布不是正方形）
        final dx = (cx - ccx) * canvasAspect, dy = cy - ccy;
        cx = ccx + (dx * cosA - dy * sinA) / canvasAspect;
        cy = ccy + dx * sinA + dy * cosA;
        final wu = w * canvasAspect;
        final rw = (wu * cosA).abs() + (h * sinA).abs();
        final rh = (wu * sinA).abs() + (h * cosA).abs();
        w = rw / canvasAspect;
        h = rh;
      }
      pts.add((t, cx, cy, w, h));
    }
    if (pts.length < 2) continue;
    pts.sort((a, b) => a.$1.compareTo(b.$1));
    final offset = pts.first.$1;
    final length = math.max(0.1, pts.last.$1 - offset);
    final flat = <double>[
      for (final p in pts) ...[p.$1 - offset, p.$2, p.$3, p.$4, p.$5],
    ];
    out.add(FaceMosaicPlan(offset, length, quantizeMosaicPath(flat), tr.best));
  }
  return out;
}
