import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/large_media_transform.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/video_processor.dart';

void main() {
  final source = MediaSource(
    path: 'source.mov',
    name: 'source',
    kind: ClipKind.video,
    duration: 1,
    w: 48,
    h: 48,
  );
  TimelineClip clip({bool mirror = false, double rotation = 0}) => TimelineClip(
    id: 1,
    sourceIndex: 0,
    track: 0,
    offset: 0,
    trimStart: 0,
    trimEnd: 1,
    scale: 100,
    mirror: mirror,
    rotation: rotation,
    cropL: .5,
    cropW: .5,
  );

  test(
    '100x export samples a bounded canvas, including video and image paths',
    () async {
      for (final kind in [ClipKind.video, ClipKind.image]) {
        final src = MediaSource(
          path: 'source.mov',
          name: 'source',
          kind: kind,
          duration: 1,
          w: 2160,
          h: 3840,
        );
        debugPrimeProbe(
          src.path,
          hasAudio: false,
          fps: 30,
          hdr: false,
          trc: '',
          dispW: src.w,
          dispH: src.h,
        );
        final spec = ExportSpec(
          sources: [src],
          clips: [clip()],
          timelineDuration: 1,
          speed: 1,
          watermarkPng: null,
          outW: 1080,
          outH: 1920,
        );
        final args = await debugBuildArguments(spec, 'out.mp4');
        final filter = args[args.indexOf('-filter_complex') + 1];
        expect(filter, contains('geq='));
        expect(filter, contains('crop=1080:1920:0:0'));
        expect(filter, isNot(contains('scale=108000:192000')));
      }
    },
  );

  final ffmpeg = Platform.environment['MARKCUT_FFMPEG'];
  test(
    'cropped mirror/rotation export keeps the visible center aligned',
    () async {
      // A right-half crop mirrored left and then rotated 90 degrees must land
      // in the top half, exactly as the preview's original-image pivot does.
      for (final kind in [ClipKind.video, ClipKind.image]) {
        final src = MediaSource(
          path: 'crop.mov',
          name: 'crop',
          kind: kind,
          duration: 1,
          w: 100,
          h: 100,
        );
        debugPrimeProbe(
          src.path,
          hasAudio: false,
          fps: 30,
          hdr: false,
          trc: '',
          dispW: 100,
          dispH: 100,
        );
        final c = clip(mirror: true, rotation: 90)..scale = 1;
        final args = await debugBuildArguments(
          ExportSpec(
            sources: [src],
            clips: [c],
            timelineDuration: 1,
            speed: 1,
            watermarkPng: null,
            outW: 100,
            outH: 100,
          ),
          'out.mp4',
        );
        final filter = args[args.indexOf('-filter_complex') + 1];
        // 50x100 crop rotates in a 112x112 transparent buffer; visible center
        // (50,25) requires that buffer's top-left at (-6,-31).
        expect(filter, contains('crop=50:100:50:0,hflip'));
        expect(filter, contains('overlay=-6:-31:'));
      }
    },
  );
  test(
    'real FFmpeg: 100x crop, mirror, rotation and alpha match output geometry',
    () async {
      final root = await Directory.systemTemp.createTemp('markcut-zoom-');
      try {
        final raw = File('${root.path}/source.rgb');
        await raw.writeAsBytes([
          for (var y = 0; y < 48; y++)
            for (var x = 0; x < 48; x++) ...[x * 4, y * 4, 60],
        ]);
        for (final (mirror, rotation) in [
          (false, 0.0),
          (true, 0.0),
          (false, 90.0),
        ]) {
          final transform = LargeMediaTransform(
            source,
            clip(mirror: mirror, rotation: rotation),
            32,
            24,
          );
          final result = await Process.run(ffmpeg!, [
            '-v',
            'error',
            '-threads',
            '1',
            '-f',
            'rawvideo',
            '-pixel_format',
            'rgb24',
            '-video_size',
            '48x48',
            '-i',
            raw.path,
            '-vf',
            transform.filter.substring(0, transform.filter.length - 1),
            '-frames:v',
            '1',
            '-f',
            'rawvideo',
            '-pix_fmt',
            'rgba',
            'pipe:1',
          ], stdoutEncoding: null);
          expect(result.exitCode, 0, reason: '${result.stderr}');
          final bytes = result.stdout as List<int>;
          expect(bytes.length, 32 * 24 * 4);
          int channel(int x, int y, int ch) => bytes[(y * 32 + x) * 4 + ch];
          if (rotation == 90) {
            expect(channel(16, 4, 3), 0);
            expect(channel(16, 20, 3), 255);
          } else {
            expect(channel(4, 12, 3), mirror ? 255 : 0);
            expect(channel(28, 12, 3), mirror ? 0 : 255);
            expect(channel(mirror ? 4 : 28, 12, 0), closeTo(94, 3));
            expect(channel(mirror ? 4 : 28, 12, 2), 60);
          }
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
    skip: ffmpeg == null
        ? 'Set MARKCUT_FFMPEG for the real decoder check'
        : false,
  );
}
