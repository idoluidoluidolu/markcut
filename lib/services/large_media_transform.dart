import 'dart:math' as math;

import '../models/timeline.dart';

/// FFmpeg's normal scale->rotate pipeline allocates scale² pixels. For large
/// zooms sample the source at inverse-transformed output coordinates instead.
/// Work surfaces depend on the source/canvas size, never on the zoom factor.
class LargeMediaTransform {
  LargeMediaTransform(
    MediaSource source,
    TimelineClip clip,
    int outW,
    int outH,
  ) {
    final aspect = source.aspect;
    final fitW = aspect >= outW / outH ? outW.toDouble() : outH * aspect;
    final fitH = fitW / aspect;
    final w = fitW * clip.scale;
    final h = fitH * clip.scale;
    final radians = clip.rotation * math.pi / 180;
    String n(double v) => v.toStringAsFixed(9);
    final cos = n(math.cos(radians)), sin = n(math.sin(radians));
    final dx = '(X-${n(clip.px * outW)})';
    final dy = '(Y-${n(clip.py * outH)})';
    var u = '(($cos*$dx+$sin*$dy)/${n(w)}+0.5)';
    final v = '((-$sin*$dx+$cos*$dy)/${n(h)}+0.5)';
    if (clip.mirror) u = '(1-$u)';

    // Keep original detail up to the app's 4K preview/export working scale.
    // A large output may itself be larger; it still never grows with zoom.
    final maxSide = math.max(4096, math.max(outW, outH));
    final rawW = math.max(2, source.w), rawH = math.max(2, source.h);
    final down = math.min(1.0, maxSide / math.max(rawW, rawH));
    rasterW = math.max(2, (rawW * down).round());
    rasterH = math.max(2, (rawH * down).round());
    final canvasW = math.max(rasterW, outW);
    final canvasH = math.max(rasterH, outH);
    final x = '($u*$rasterW-0.5)', y = '($v*$rasterH-0.5)';
    final inside =
        'between($u,${n(clip.cropL)},${n(clip.cropL + clip.cropW)})'
        '*between($v,${n(clip.cropT)},${n(clip.cropT + clip.cropH)})';
    filter =
        'scale=$rasterW:$rasterH:flags=lanczos,format=gbrap,'
        'pad=$canvasW:$canvasH:0:0:color=black@0,'
        "geq=r='r($x,$y)':g='g($x,$y)':b='b($x,$y)':"
        "a='if($inside,alpha($x,$y)*${n(clip.opacity.clamp(0.0, 1.0))},0)':"
        'interpolation=bilinear,crop=$outW:$outH:0:0,format=rgba,';
  }

  late final int rasterW;
  late final int rasterH;
  late final String filter;
}
