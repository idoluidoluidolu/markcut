import 'dart:math' as math;

/// Bound rasterization and transport together. Large previews must not fall
/// back to PNG encoding between gestures. Export uses its own renderer.
int overlayPreviewMaxPixels({required bool fast}) =>
    fast ? 512 * 1024 : 2 * 1024 * 1024;

/// Sample at the actual composition canvas size. Export has its own renderer.
/// Retain the existing 1080 fallback until the native canvas is known.
int overlayPreviewShortSide(
  double width,
  double height, {
  required bool fast,
  required bool text,
}) {
  final edge = math.min(width, height);
  final full = edge.isFinite && edge > 0 ? edge.ceil().clamp(540, 1080) : 1080;
  return fast ? math.min(full, text ? 720 : 540) : full;
}
