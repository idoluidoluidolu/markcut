import 'dart:math' as math;
import 'dart:ui';

import '../models/timeline.dart';

/// Unrotated selection rectangle placed at the *rotated visible* center.
/// Rotating this rectangle around its own center then matches the cropped media.
Rect mediaCropRect(Rect full, TimelineClip clip) {
  final left = clip.mirror ? 1 - clip.cropL - clip.cropW : clip.cropL;
  final dx = (left + clip.cropW / 2 - .5) * full.width;
  final dy = (clip.cropT + clip.cropH / 2 - .5) * full.height;
  final angle = clip.rotation * math.pi / 180;
  return Rect.fromCenter(
    center:
        full.center +
        Offset(
          dx * math.cos(angle) - dy * math.sin(angle),
          dx * math.sin(angle) + dy * math.cos(angle),
        ),
    width: full.width * clip.cropW,
    height: full.height * clip.cropH,
  );
}

Offset mediaVisibleOffset(
  TimelineClip clip,
  double sourceAspect,
  double canvasAspect,
) {
  final fitW = sourceAspect >= canvasAspect ? canvasAspect : sourceAspect;
  final fitH = fitW / sourceAspect;
  final rect = mediaCropRect(
    Rect.fromCenter(
      center: Offset.zero,
      width: fitW * clip.scale,
      height: fitH * clip.scale,
    ),
    clip,
  );
  return Offset(rect.center.dx / canvasAspect, rect.center.dy);
}

Offset mediaVisibleCenter(
  TimelineClip clip,
  double sourceAspect,
  double canvasAspect,
) =>
    Offset(clip.px, clip.py) +
    mediaVisibleOffset(clip, sourceAspect, canvasAspect);

/// A heavily cropped source may need its original center outside 0..1 to put
/// the remaining picture on the canvas. Never clamp the original center.
void placeMediaVisibleCenter(
  TimelineClip clip,
  double sourceAspect,
  double canvasAspect,
  Offset center,
) {
  final original =
      center - mediaVisibleOffset(clip, sourceAspect, canvasAspect);
  clip.px = original.dx;
  clip.py = original.dy;
}
