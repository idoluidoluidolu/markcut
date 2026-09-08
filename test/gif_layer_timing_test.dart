import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/video_processor.dart';

ExportSpec _spec({
  String path = 'loop.gif',
  double trimStart = 1.2,
  double trimEnd = 3.8,
  double clipSpeed = 2,
  double globalSpeed = 1,
  double offset = 2,
  bool reverse = false,
  bool gif = true,
  int fps = 30,
}) {
  final clip = TimelineClip(
    id: 1,
    sourceIndex: 0,
    trimStart: trimStart,
    trimEnd: trimEnd,
    speed: clipSpeed,
    offset: offset,
    track: 0,
    reverse: reverse,
  );
  return ExportSpec(
    sources: [
      MediaSource(
        path: path,
        name: 'GIF',
        kind: ClipKind.image,
        isGif: gif,
        duration: 1,
        w: 16,
        h: 16,
      ),
    ],
    clips: [clip],
    timelineDuration: clip.end,
    speed: globalSpeed,
    watermarkPng: null,
    outW: 32,
    outH: 32,
    fps: fps,
  );
}

void main() {
  test('GIF 修剪與片段速度按素材時間取樣，輸入足夠循環到 trimEnd', () async {
    final command = await debugBuildCommand(_spec(), 'out.mp4');
    expect(command, contains('-ignore_loop 0 -t 4.300 -i "loop.gif"'));
    expect(command, contains('setpts=PTS-1.200000/TB'));
    expect(command, contains('fps=fps=15.000000:start_time=0:round=up'));
    expect(command, contains('trim=duration=2.600000'));
    expect(command, contains('setpts=(PTS-STARTPTS)/2.000000+0.000/TB'));
  });

  test('GIF 全域速度和片段速度相乘，分段起點換回來源時間', () async {
    final command = await debugBuildCommand(
      _spec(globalSpeed: 2),
      'out.mp4',
      winStart: 1.25,
      winEnd: 1.5,
    );
    expect(command, contains('setpts=PTS-2.200000/TB'));
    expect(command, contains('fps=fps=7.500000:start_time=0:round=up'));
    expect(command, contains('trim=duration=1.000000'));
    expect(command, contains('setpts=(PTS-STARTPTS)/4.000000+0.250/TB'));
    expect(command, contains('-ignore_loop 0 -t 3.700 -i "loop.gif"'));
  });

  test('倒轉 GIF 的中段取正確來源區間，縮圖之後才 reverse', () async {
    final command = await debugBuildCommand(
      _spec(reverse: true, globalSpeed: 2),
      'out.mp4',
      winStart: 1.25,
      winEnd: 1.5,
    );
    expect(command, contains('setpts=PTS-1.800000/TB'));
    expect(command, contains('trim=duration=1.000000'));
    expect(
      command,
      contains('reverse,settb=AVTB,setpts=(PTS-STARTPTS)/4.000000'),
    );
    expect(
      command.indexOf('scale=32:32'),
      lessThan(command.indexOf('reverse,')),
    );
    expect(command, contains('-ignore_loop 0 -t 3.300 -i "loop.gif"'));
  });

  test('靜態圖片保留原本循環輸入和淡化時間，不走 GIF 補幀', () async {
    final command = await debugBuildCommand(_spec(gif: false), 'out.mp4');
    expect(command, contains('-f image2 -loop 1'));
    expect(command, isNot(contains('fps=fps=')));
    expect(command, isNot(contains('reverse,')));
  });

  // opt-in 的實際 FFmpeg 像素測試。一般 Flutter CI 不一定裝有 ffmpeg；
  // 設 MARKCUT_FFMPEG 為執行檔路徑即可驗證同一條完整 filter graph。
  final ffmpeg = Platform.environment['MARKCUT_FFMPEG'];
  test(
    '實際 GIF 像素：修剪落在幀中、變速、倒轉、循環及跨分段都一致',
    () async {
      final dir = await Directory.systemTemp.createTemp('markcut_gif_timing_');
      addTearDown(() => dir.delete(recursive: true));
      final rgb = File('${dir.path}/frames.rgb');
      const colors = <List<int>>[
        [255, 0, 0],
        [0, 255, 0],
        [0, 0, 255],
        [255, 255, 0],
      ];
      await rgb.writeAsBytes([
        for (final color in colors)
          for (var p = 0; p < 16 * 16; p++) ...color,
      ]);
      final gif = '${dir.path}/loop.gif';
      Future<ProcessResult> run(
        List<String> args, {
        bool binary = false,
      }) async {
        final result = await Process.run(ffmpeg!, [
          '-hide_banner',
          '-loglevel',
          'error',
          ...args,
        ], stdoutEncoding: binary ? null : systemEncoding);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return result;
      }

      await run([
        '-y',
        '-f',
        'rawvideo',
        '-pixel_format',
        'rgb24',
        '-video_size',
        '16x16',
        '-framerate',
        '4',
        '-i',
        rgb.path,
        '-loop',
        '0',
        gif,
      ]);
      final cases = [
        (_spec(path: gif, trimStart: 0.35, offset: 0.2, fps: 60), 0.2, 1.1),
        (_spec(path: gif, clipSpeed: 0.75, globalSpeed: 2, fps: 60), 1.25, 1.6),
        (
          _spec(
            path: gif,
            reverse: true,
            clipSpeed: 1,
            globalSpeed: 2,
            fps: 60,
          ),
          1.25,
          1.6,
        ),
        (_spec(path: gif, clipSpeed: 0.5, globalSpeed: 0.5, fps: 60), 5.1, 6.3),
      ];
      for (var index = 0; index < cases.length; index++) {
        final (spec, start, end) = cases[index];
        final output = '${dir.path}/out$index.mp4';
        final cmd = await debugBuildCommand(
          spec,
          output,
          winStart: start,
          winEnd: end,
          videoOnly: true,
        );
        // 電腦沒有手機編碼器；只替換 encoder，輸入與 filter graph 原封執行。
        final args = FFmpegKitConfig.parseArguments(
          cmd
              .replaceAll('h264_mediacodec', 'libx264')
              .replaceAll('h264_videotoolbox', 'libx264'),
        );
        await run(['-filter_complex_threads', '1', ...args]);
        final decoded = await run([
          '-i',
          output,
          '-vf',
          'scale=1:1',
          '-fps_mode',
          'passthrough',
          '-f',
          'rawvideo',
          '-pix_fmt',
          'rgb24',
          '-',
        ], binary: true);
        final pixels = Uint8List.fromList(decoded.stdout as List<int>);
        expect(pixels.length, greaterThan(9));
        final fps = outputFps(0, spec.outW, spec.outH, want: spec.fps);
        var checked = 0;
        for (var frame = 0; frame < pixels.length ~/ 3; frame++) {
          final t = (start + frame / fps) * spec.speed;
          final source = spec.clips.single.sourceTimeAt(t);
          final phase = source % 1;
          // 邊界格受 codec 時基與 reverse 的半開區間影響；比較距離邊界
          // 至少一格的色塊，另有上面的 filter 測試精確核對時間換算。
          final withinColor = (phase * 4) % 1;
          final margin = spec.speed * spec.clips.single.speed / fps * 4 + 0.02;
          if (withinColor < margin || withinColor > 1 - margin) continue;
          final expected = (phase * 4).floor();
          var actual = 0;
          var best = double.infinity;
          for (var c = 0; c < colors.length; c++) {
            var error = 0.0;
            for (var ch = 0; ch < 3; ch++) {
              final diff = pixels[frame * 3 + ch] - colors[c][ch];
              error += diff * diff;
            }
            if (error < best) {
              best = error;
              actual = c;
            }
          }
          expect(
            actual,
            expected,
            reason: 'case=$index frame=$frame source=$source',
          );
          checked++;
        }
        expect(checked, greaterThan(0), reason: 'case=$index 未比較到任何影格');
      }
    },
    skip: ffmpeg == null ? '設 MARKCUT_FFMPEG 以執行實際編解碼測試' : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
