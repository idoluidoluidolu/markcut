import 'dart:math' as math;

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
