import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../models/mosaic.dart';
import '../services/brush_mask.dart';
import '../services/mosaic_patch_painter.dart'
    show strokeBoundsPx, strokeFeatherPx;

/// 預覽上的筆刷馬賽克（沒有合成播放器時：Android、Web、iOS 合成還沒
/// 上來的那一下）。只碼筆畫本身，不是整個包圍盒——跟 iOS 合成器、
/// FFmpeg 匯出同一塊範圍（規則見 brush_mask.dart）。
///
/// 純色直接畫匯出遮罩那一筆（同一個畫家，連柔邊都一樣）。
/// 像素化／模糊要讀底下的畫面，只能用 BackdropFilter，而它吃不了半透明
/// 遮罩，所以柔邊跟方形的預覽同一招：同心 6 圈、越裡面越重，
/// 每一圈是「筆畫往外長多寬」的裁切形狀
class BrushMosaicPreview extends StatelessWidget {
  /// 筆畫（0~1 畫布座標，x,y 交錯攤平）
  final List<double> stroke;

  /// 筆刷直徑（畫布短邊比例）
  final double brush;
  final MosaicStyle style;

  /// 預覽畫布的大小
  final Size canvas;

  /// 這個 widget 在畫布上的位置（筆畫的點要換成自己的座標）
  final Rect rect;

  /// 像素化的 shader（shaders/mosaic.frag）；平台不支援時退回模糊
  final ui.FragmentProgram? pixelShader;

  const BrushMosaicPreview({
    super.key,
    required this.stroke,
    required this.brush,
    required this.style,
    required this.canvas,
    required this.rect,
    this.pixelShader,
  });

  @override
  Widget build(BuildContext context) {
    final w = canvas.width, h = canvas.height;
    final brushPx = brush * math.min(w, h);
    final featherPx = strokeFeatherPx(style, brushPx);
    final onCanvas = brushStrokePoints(stroke, w, h);
    final pts = [for (final p in onCanvas) p - rect.topLeft];
    if (style.type == 2) {
      return CustomPaint(
        painter: _SolidStrokePainter(
          pts,
          brushPx,
          featherPx,
          Color(style.color),
        ),
        child: const SizedBox.expand(),
      );
    }

    // 效果強度跟方形的預覽同一條公式（見 video_editor_screen 的馬賽克
    // 圖層）；像素格數照包圍盒落在畫面裡的寬度算，跟 iOS 一樣
    final sigma = (1 + 6 * style.strength) * math.min(w, h) / 1080 * 2.4;
    final bounds = strokeBoundsPx(onCanvas, brushPx, featherPx);
    final boxW = math.max(
      1.0,
      math.min(bounds.right, w) - math.max(bounds.left, 0),
    );
    final cells = (26 - 20 * style.strength).round().clamp(4, 40);
    final cell = math.max(
      2.0,
      boxW * (MediaQuery.maybeDevicePixelRatioOf(context) ?? 1) / cells,
    );
    ui.ImageFilter effect(double k) {
      final prog = pixelShader;
      if (style.type == 0 && prog != null) {
        try {
          // 0,1 = u_size(引擎自動填),2 = u_cell
          final sh = prog.fragmentShader();
          sh.setFloat(2, math.max(2.0, cell * k));
          return ui.ImageFilter.shader(sh);
        } catch (_) {}
      }
      return ui.ImageFilter.blur(sigmaX: sigma * k, sigmaY: sigma * k);
    }

    // 圈的範圍照匯出遮罩的暈開寬度排：遮罩是寬 lineW 的線再暈開 σ，
    // 最外圈排到遮罩幾乎歸零處（半寬＋2σ）、最內圈到幾乎全實處（半寬−2σ，
    // 柔邊很大時保留一點，不然最重的那一圈會縮成一條線）
    final soft = featherPx >= 1;
    final half = math.max(1.0, brushPx - (soft ? featherPx : 0)) / 2;
    final sg = featherPx / 2;
    final outer = soft ? half + 2 * sg : half;
    final inner = soft ? math.max(half - 2 * sg, half * 0.25) : half;
    final n = soft ? 6 : 1;
    return Stack(
      fit: StackFit.expand,
      // 柔邊的尾巴可能伸出包圍盒一點，不要被這一層切掉
      clipBehavior: Clip.none,
      children: [
        for (var i = 0; i < n; i++)
          ClipPath(
            clipper: _OutlineClipper(
              pts,
              n == 1 ? half : outer - (outer - inner) * i / (n - 1),
            ),
            child: BackdropFilter(
              filter: effect((i + 1) / n),
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }
}

class _OutlineClipper extends CustomClipper<Path> {
  final List<Offset> pts;
  final double half;

  _OutlineClipper(this.pts, this.half);

  @override
  Path getClip(Size size) => brushStrokeOutline(pts, half);

  @override
  bool shouldReclip(_OutlineClipper old) =>
      old.half != half || !listEquals(old.pts, pts);
}

class _SolidStrokePainter extends CustomPainter {
  final List<Offset> pts;
  final double brushPx;
  final double featherPx;
  final Color color;

  _SolidStrokePainter(this.pts, this.brushPx, this.featherPx, this.color);

  @override
  void paint(Canvas canvas, Size size) =>
      paintBrushStroke(canvas, pts, brushPx, featherPx, color);

  @override
  bool shouldRepaint(_SolidStrokePainter old) =>
      old.brushPx != brushPx ||
      old.featherPx != featherPx ||
      old.color != color ||
      !listEquals(old.pts, pts);
}
