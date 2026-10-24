import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 馬賽克的框線：實線（選取中、碼著的臉）或虛線（點掉不碼的臉，
/// 還看得到它在哪、點一下碼回去）。照片編輯器與影片剪輯共用
class MosaicOutlinePainter extends CustomPainter {
  final bool oval;
  final bool dashed;
  final Color color;
  final double width;

  const MosaicOutlinePainter({
    required this.oval,
    required this.dashed,
    required this.color,
    required this.width,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = (Offset.zero & size).deflate(width / 2);
    if (r.width <= 0 || r.height <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    final path = oval ? (Path()..addOval(r)) : (Path()..addRect(r));
    if (!dashed) {
      canvas.drawPath(path, paint);
      return;
    }
    // 虛線：沿著框線一段畫、一段空（長度跟線寬成比例，小臉也看得出來）
    final dash = math.max(3.0, width * 3);
    final gap = math.max(2.5, width * 2.2);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          paint,
        );
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(MosaicOutlinePainter old) =>
      old.oval != oval ||
      old.dashed != dashed ||
      old.color != color ||
      old.width != width;
}
