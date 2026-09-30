import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/media_geometry.dart';

void main() {
  test(
    'a corner crop can reach the center even when original center is off-canvas',
    () {
      for (final mirror in [false, true]) {
        for (final rotation in [0.0, 90.0, 37.0, -90.0]) {
          final clip = TimelineClip(
            id: 1,
            sourceIndex: 0,
            track: 0,
            offset: 0,
            trimStart: 0,
            trimEnd: 1,
            scale: 20,
            cropL: .8,
            cropT: .7,
            cropW: .1,
            cropH: .15,
            mirror: mirror,
            rotation: rotation,
          );
          placeMediaVisibleCenter(clip, 16 / 9, 9 / 16, const Offset(.5, .5));
          final center = mediaVisibleCenter(clip, 16 / 9, 9 / 16);
          expect(center.dx, closeTo(.5, 1e-9));
          expect(center.dy, closeTo(.5, 1e-9));
          expect(
            clip.px < 0 || clip.px > 1 || clip.py < 0 || clip.py > 1,
            isTrue,
          );
          final restored = TimelineClip.fromJson(clip.toJson());
          expect(mediaVisibleCenter(restored, 16 / 9, 9 / 16), center);
        }
      }
    },
  );

  test('rotated cropped selection frame has the correct visible center', () {
    final clip = TimelineClip(
      id: 1,
      sourceIndex: 0,
      track: 0,
      offset: 0,
      trimStart: 0,
      trimEnd: 1,
      cropL: .5,
      cropW: .5,
      rotation: 90,
    );
    final rect = mediaCropRect(const Rect.fromLTWH(0, 0, 200, 100), clip);
    expect(rect.center.dx, closeTo(100, 1e-9));
    expect(rect.center.dy, closeTo(100, 1e-9));
    expect(rect.size, const Size(100, 100));
  });
}
