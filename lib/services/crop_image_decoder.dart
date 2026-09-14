import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

const cropPreviewMaxSide = 2048;

/// Read metadata before allocating pixels. A crop UI never needs the full
/// 12/48 MP original merely to display a selection rectangle.
Future<({ui.Image image, int sourceWidth, int sourceHeight})> decodeCropImage(
  Uint8List bytes, {
  required int maxSide,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width, h = descriptor.height;
    final downsample = math.max(w, h) > maxSide;
    codec = await descriptor.instantiateCodec(
      targetWidth: downsample && w >= h ? maxSide : null,
      targetHeight: downsample && h > w ? maxSide : null,
    );
    final image = (await codec.getNextFrame()).image;
    // The decoded orientation is authoritative (e.g. EXIF portrait sources).
    final swapped = w != h && (image.width > image.height) != (w > h);
    return (
      image: image,
      sourceWidth: swapped ? h : w,
      sourceHeight: swapped ? w : h,
    );
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Preserve original crop resolution, independent of the small UI preview.
/// For a small crop this may require the full source at confirmation time;
/// never silently turn a detailed 4K crop into a crop of the 2K preview.
({int width, int height, int decodeSide}) cropOutputPlan(
  int sourceWidth,
  int sourceHeight,
  ui.Rect fraction, {
  int? maxSide,
}) {
  final sourceW = math.max(1, (sourceWidth * fraction.width).round());
  final sourceH = math.max(1, (sourceHeight * fraction.height).round());
  final scale = maxSide == null
      ? 1.0
      : math.min(1.0, math.max(1, maxSide) / math.max(sourceW, sourceH));
  return (
    width: math.max(1, (sourceW * scale).round()),
    height: math.max(1, (sourceH * scale).round()),
    decodeSide: math.max(
      1,
      (math.max(sourceWidth, sourceHeight) * scale).ceil(),
    ),
  );
}
