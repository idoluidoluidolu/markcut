import 'dart:math' as math;
import 'dart:ui' as ui;

import '../models/watermark_settings.dart';
import 'collage_compose.dart';
import 'watermark_renderer.dart';

/// 拼圖所有預覽圖共用的總量上限（含版型縮小後暫時沒顯示的那幾張）。
/// 匯出與裁切一律回原檔重解，不吃這份縮小過的預覽
const kCollagePreviewBytes = 64 << 20;
const kCollagePreviewMaxSide = 1600;

/// 預覽長邊只在這幾級之間換：照片數一多就往下一級。
///
/// 不用連續公式（√(上限÷張數)）：照片一張一張加進來時，連續公式每加
/// 一張上限就小一點點，前面每一張都要重解一次——一路加到 30 張要重解
/// 四百多次。分級之後一路加到 30 張最多換四次（1280／1024／820／656）
const _kCollagePreviewLevels = [1600, 1280, 1024, 820, 656, 524, 420, 336];

int collagePreviewSide(int count, {int byteBudget = kCollagePreviewBytes}) {
  final n = math.max(1, count);
  for (final side in _kCollagePreviewLevels) {
    if (n * side * side * 4 <= byteBudget) return side;
  }
  // 遠超過拼圖上限的張數（上限是 30）才會走到這裡
  return math.max(1, math.sqrt(byteBudget / (4 * n)).floor());
}

/// Export in bounded groups of source rasters. A Picture retains images used by
/// drawImageRect, so disposing a decoded image alone does not release its pixels
/// until that Picture has been rasterized and disposed.
///
/// Source rectangles are captured from the preview in normalized coordinates:
/// re-decoding at export resolution must not change pan, zoom, or crop.
Future<ui.Image> composeCollageFromSources(
  CollageLayout layout,
  List<ui.Image?> previews, {
  required Future<ui.Image> Function(int index, int maxSide) decode,
  WatermarkSettings? watermark,
  double? longSide,
  ui.Color? background,
  int sourceByteBudget = kCollagePreviewBytes,
}) async {
  final (w, h) = collageCanvasSize(layout, longSide ?? collageLongSide(layout));
  final draws = <({int index, ui.Rect src, ui.Rect dst})>[];
  void add(int index, ui.Rect dst, CollageCellFit? fit, ui.Rect crop) {
    if (index < 0 || index >= previews.length) return;
    final image = previews[index];
    if (image == null || dst.isEmpty) return;
    final src = fit == null
        ? collageCoverSrc(image, dst.width / dst.height, crop: crop)
        : collageSrcRect(image, fit, dst.width / dst.height);
    draws.add((
      index: index,
      src: ui.Rect.fromLTRB(
        src.left / image.width,
        src.top / image.height,
        src.right / image.width,
        src.bottom / image.height,
      ),
      dst: dst,
    ));
  }

  if (layout.free) {
    for (final item in layout.items) {
      add(
        item.img,
        ui.Rect.fromLTWH(
          item.rect.left * w,
          item.rect.top * h,
          item.rect.width * w,
          item.rect.height * h,
        ),
        null,
        item.crop,
      );
    }
  } else {
    final cw = w / layout.cols, ch = h / layout.rows;
    for (var i = 0; i < layout.cellCount; i++) {
      add(
        i < layout.order.length ? layout.order[i] : -1,
        ui.Rect.fromLTWH(
          (i % layout.cols) * cw,
          (i ~/ layout.cols) * ch,
          cw,
          ch,
        ),
        i < layout.fits.length ? layout.fits[i] : CollageCellFit(),
        kCollageFullCrop,
      );
    }
  }

  ui.PictureRecorder? recorder;
  ui.Canvas? canvas;
  ui.Image? composed;
  final sources = <ui.Image>[];
  var pendingBytes = 0;
  void begin() {
    recorder = ui.PictureRecorder();
    canvas = ui.Canvas(recorder!);
    if (composed != null) {
      canvas!.drawImage(composed!, ui.Offset.zero, ui.Paint());
    } else if (background != null) {
      canvas!.drawRect(
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..color = background,
      );
    }
  }

  Future<void> flush() async {
    final picture = recorder!.endRecording();
    recorder = null;
    try {
      final next = await picture.toImage(w, h);
      composed?.dispose();
      composed = next;
    } finally {
      picture.dispose();
      for (final source in sources) {
        source.dispose();
      }
      sources.clear();
      pendingBytes = 0;
    }
  }

  begin();
  try {
    for (final draw in draws) {
      // Keep at least the former 1600px export quality; increase it for a large
      // cell/crop, within one source's memory allowance.
      final needed = math.max(
        draw.dst.width / draw.src.width,
        draw.dst.height / draw.src.height,
      );
      final maxSide = math.min(
        math.max(kCollagePreviewMaxSide, needed.ceil()),
        math.max(1, math.sqrt(sourceByteBudget / 4).floor()),
      );
      final upperBytes = maxSide * maxSide * 4;
      if (sources.isNotEmpty && pendingBytes + upperBytes > sourceByteBudget) {
        await flush();
        begin();
      }
      final image = await decode(draw.index, maxSide);
      sources.add(image);
      pendingBytes += image.width * image.height * 4;
      canvas!.drawImageRect(
        image,
        ui.Rect.fromLTRB(
          draw.src.left * image.width,
          draw.src.top * image.height,
          draw.src.right * image.width,
          draw.src.bottom * image.height,
        ),
        draw.dst,
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
    }
    if (!layout.free && layout.lines) {
      final cw = w / layout.cols, ch = h / layout.rows;
      final t = layout.gapN * w;
      final paint = ui.Paint()..color = ui.Color(layout.lineColor);
      for (var c = 1; c < layout.cols; c++) {
        canvas!.drawRect(
          ui.Rect.fromLTWH(c * cw - t / 2, 0, t, h.toDouble()),
          paint,
        );
      }
      for (var r = 1; r < layout.rows; r++) {
        canvas!.drawRect(
          ui.Rect.fromLTWH(0, r * ch - t / 2, w.toDouble(), t),
          paint,
        );
      }
    }
    if (watermark != null) {
      await WatermarkRenderer.drawMarks(
        canvas!,
        watermark,
        w.toDouble(),
        h.toDouble(),
      );
    }
    await flush();
    final result = composed!;
    composed = null;
    return result;
  } finally {
    recorder?.endRecording().dispose();
    composed?.dispose();
    for (final source in sources) {
      source.dispose();
    }
  }
}
