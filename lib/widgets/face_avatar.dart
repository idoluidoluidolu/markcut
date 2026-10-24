import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 時間軸上一個人的頭像：影片裡這張臉最清楚的那一格（轉正後的畫面）
/// ＋臉框（那一格的 0~1）。圖只在記憶體裡，草稿只記「哪一格、哪個框」
///（見 MediaSource.mosaicFaceAt）
class FaceThumb {
  final ui.Image frame;
  final Rect box;

  const FaceThumb(this.frame, this.box);
}

/// 臉框外留一點（頭髮、下巴），裁成正方形
Rect faceAvatarCrop(Rect box, double iw, double ih) {
  final side = math.min(
    math.max(box.width * iw, box.height * ih) * 1.5,
    math.min(iw, ih),
  );
  final l = (box.center.dx * iw - side / 2).clamp(0.0, iw - side);
  final t = (box.center.dy * ih - side / 2).clamp(0.0, ih - side);
  return Rect.fromLTWH(l, t, side, side);
}

/// 圓形頭像
class FaceAvatar extends StatelessWidget {
  final FaceThumb face;
  final double size;

  const FaceAvatar(this.face, {super.key, this.size = 26});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _FacePainter(face)),
  );
}

class _FacePainter extends CustomPainter {
  final FaceThumb face;

  _FacePainter(this.face);

  @override
  void paint(Canvas canvas, Size size) {
    final img = face.frame;
    final dst = Offset.zero & size;
    canvas.clipPath(Path()..addOval(dst));
    canvas.drawImageRect(
      img,
      faceAvatarCrop(face.box, img.width.toDouble(), img.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_FacePainter old) =>
      !identical(old.face.frame, face.frame) || old.face.box != face.box;
}
