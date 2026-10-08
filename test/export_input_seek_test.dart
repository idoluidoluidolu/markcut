import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/video_processor.dart';

ExportSpec specFor(
  String path, {
  double start = 8.125,
  double end = 10.625,
  double speed = 1,
  double clipSpeed = 1,
  double offset = 0,
  bool reverse = false,
  bool shared = false,
  bool audioOnly = false,
}) {
  debugPrimeProbe(path, hasAudio: true, fps: 30, dispW: 64, dispH: 64);
  final clips = [
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: start,
      trimEnd: end,
      offset: offset,
      track: 0,
      speed: clipSpeed,
      reverse: reverse,
      fadeIn: 0.15,
      fadeOut: 0.2,
    ),
    if (shared)
      TimelineClip(
        id: 2,
        sourceIndex: 0,
        trimStart: 3.25,
        trimEnd: 5.75,
        offset: offset,
        track: 1,
        speed: clipSpeed,
        opacity: 0.5,
      ),
  ];
  return ExportSpec(
    sources: [
      MediaSource(
        path: path,
        name: 'source',
        kind: audioOnly ? ClipKind.audio : ClipKind.video,
        duration: 12,
        w: 64,
        h: 64,
      ),
    ],
    clips: clips,
    timelineDuration: clips.map((c) => c.end).reduce((a, b) => a > b ? a : b),
    speed: speed,
    watermarkPng: null,
    outW: 64,
    outH: 64,
    fps: 30,
  );
}

String filterOf(List<String> args) => args[args.indexOf('-filter_complex') + 1];

void main() {
  test(
    'late trims seek before input and rebase both video and audio',
    () async {
      final args = await debugBuildArguments(specFor('long.mp4'), 'out.mp4');
      expect(args.sublist(args.indexOf('-ss'), args.indexOf('-i') + 2), [
        '-ss',
        '7.000',
        '-i',
        'long.mp4',
      ]);
      expect(filterOf(args), contains('trim=start=1.125:end=3.625'));
      expect(filterOf(args), contains('atrim=start=1.125:end=3.625'));
    },
  );

  test(
    'segment seek follows global speed, clip speed and timeline offset',
    () async {
      final spec = specFor(
        'long.mp4',
        start: 20.25,
        end: 32.25,
        speed: 1.5,
        clipSpeed: 2,
        offset: 3,
      );
      final args = await debugBuildArguments(
        spec,
        'out.mp4',
        winStart: 2.5,
        winEnd: 3,
        videoOnly: true,
      );
      expect(args[args.indexOf('-ss') + 1], '20.000');
      expect(filterOf(args), contains('trim=start=1.750:end=3.250'));
      expect(filterOf(args), contains('(PTS-STARTPTS)/3.000000'));
    },
  );

  test('shared source seeks to the earliest consumer', () async {
    final args = await debugBuildArguments(
      specFor('shared.mp4', shared: true),
      'out.mp4',
    );
    expect(args.where((arg) => arg == '-i').length, 1);
    expect(args[args.indexOf('-ss') + 1], '2.000');
    expect(filterOf(args), contains('trim=start=6.125:end=8.625'));
    expect(filterOf(args), contains('trim=start=1.250:end=3.750'));
  });

  test(
    'audio mux seeks each source once and retains reverse/tempo/delay',
    () async {
      final spec = specFor(
        'audio.m4a',
        reverse: true,
        audioOnly: true,
        speed: 2,
        clipSpeed: 0.5,
        offset: 3,
      );
      final args = (await debugBuildAudioMuxArguments(
        spec,
        'joined.mp4',
        'out.mp4',
      ))!;
      expect(args.take(3), ['-y', '-i', 'joined.mp4']);
      expect(args.sublist(3, 7), ['-ss', '7.000', '-i', 'audio.m4a']);
      expect(filterOf(args), contains('atrim=start=1.125:end=3.625,areverse,'));
      expect(filterOf(args), contains('adelay=1500'));
    },
  );

  test('initial trims keep their existing input and timestamps', () async {
    final args = await debugBuildArguments(
      specFor('start.mp4', start: 0.2, end: 1.2),
      'out.mp4',
    );
    expect(args, isNot(contains('-ss')));
    expect(filterOf(args), contains('trim=start=0.200:end=1.200'));
  });

  final ffmpeg = Platform.environment['MARKCUT_FFMPEG'];
  test(
    'real FFmpeg: seek preserves every output frame and audio sample',
    () async {
      final dir = await Directory.systemTemp.createTemp('markcut_export_seek_');
      addTearDown(() => dir.delete(recursive: true));
      Future<ProcessResult> run(List<String> args) async {
        final result = await Process.run(ffmpeg!, [
          '-hide_banner',
          '-loglevel',
          'error',
          '-filter_complex_threads',
          '1',
          ...args,
        ]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return result;
      }

      final input = '${dir.path}/long.mp4';
      await run([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=64x64:rate=30:duration=12',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=733:sample_rate=44100:duration=12',
        '-c:v',
        'libx264',
        '-g',
        '30',
        '-bf',
        '2',
        '-c:a',
        'aac',
        // 雜訊替代（PNS）關掉：解碼端用亂數補那幾個頻帶，亂數狀態跟
        // 「從哪一包開始解」有關，跳轉前後會差 ±1 個最低位的雜訊（實測
        // 最大 2e-5、時間點零偏移）。關掉才能逐位元比對時間點有沒有歪
        '-aac_pns',
        '0',
        input,
      ]);
      // 手機素材常見的兩種時間軸：29.97fps 放在 1/600 的時間刻度裡
      //（每格 20.02 刻，捨入後格距不等），聲音又比畫面晚 0.3 秒才開始
      final ntsc = '${dir.path}/ntsc.mov';
      await run([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=64x64:rate=30000/1001:duration=12',
        '-itsoffset',
        '0.3',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=521:sample_rate=48000:duration=11',
        '-c:v',
        'libx264',
        '-g',
        '30',
        '-bf',
        '2',
        '-video_track_timescale',
        '600',
        '-c:a',
        'aac',
        '-aac_pns',
        '0',
        ntsc,
      ]);

      // Replace only platform encoders/container with lossless desktop codecs;
      // input seeking, filters, frame rate and timing run exactly as in the app.
      List<String> desktop(List<String> args) {
        final result = <String>[];
        const discard = {'-b:v', '-maxrate', '-bufsize', '-b:a', '-movflags'};
        for (var i = 0; i < args.length; i++) {
          if (discard.contains(args[i])) {
            i++;
            continue;
          }
          if (args[i] == '-hwaccel') {
            i++;
            continue;
          }
          result.add(switch (args[i]) {
            'h264_mediacodec' || 'h264_videotoolbox' => 'ffv1',
            'aac' => 'pcm_s16le',
            'nv12' => 'yuv420p',
            _ => args[i],
          });
        }
        return result;
      }

      final cases = [
        (specFor(input), 0.0, null, false),
        (
          specFor(input, speed: 1.5, clipSpeed: 0.75, offset: 0.4),
          0.0,
          null,
          false,
        ),
        (specFor(input, reverse: true), 0.0, null, false),
        (specFor(input, shared: true), 0.0, null, false),
        (
          specFor(input, start: 0, end: 11, speed: 1.5, clipSpeed: 0.75),
          6.1,
          7.3,
          true,
        ),
        (specFor(ntsc), 0.0, null, false),
        (
          specFor(ntsc, start: 9.37, end: 10.9, clipSpeed: 1.25),
          0.0,
          null,
          false,
        ),
        (specFor(ntsc, shared: true), 0.0, null, false),
      ];
      for (var index = 0; index < cases.length; index++) {
        final (spec, start, end, videoOnly) = cases[index];
        final signatures = <String>[];
        for (final seek in [false, true]) {
          final out = '${dir.path}/case_${index}_$seek.nut';
          await run(
            desktop(
              await debugBuildArguments(
                spec,
                out,
                winStart: start,
                winEnd: end,
                videoOnly: videoOnly,
                seekInputs: seek,
              ),
            ),
          );
          final video = await run([
            '-i',
            out,
            '-map',
            '0:v',
            '-f',
            'framemd5',
            '-',
          ]);
          final audio = videoOnly
              ? ''
              : (await run([
                  '-i',
                  out,
                  '-map',
                  '0:a',
                  '-c:a',
                  'pcm_s16le',
                  '-f',
                  'md5',
                  '-',
                ])).stdout;
          signatures.add('${video.stdout}\n$audio');
        }
        expect(
          signatures[1],
          signatures[0],
          reason: 'case $index changed output',
        );
      }
      // The segmented export's separate audio pass has its own seek/rebase path.
      for (final (n, source) in [input, ntsc].indexed) {
        for (final reverse in [false, true]) {
          final spec = specFor(
            source,
            shared: true,
            reverse: reverse,
            speed: 1.5,
            clipSpeed: 0.75,
            offset: 0.4,
          );
          final hashes = <String>[];
          for (final seek in [false, true]) {
            final out = '${dir.path}/mux_${n}_${reverse}_$seek.nut';
            await run(
              desktop(
                (await debugBuildAudioMuxArguments(
                  spec,
                  source,
                  out,
                  seekInputs: seek,
                ))!,
              ),
            );
            hashes.add(
              (await run([
                '-i',
                out,
                '-map',
                '0:a',
                '-c:a',
                'pcm_s16le',
                '-f',
                'md5',
                '-',
              ])).stdout.toString(),
            );
          }
          expect(
            hashes[1],
            hashes[0],
            reason: 'audio mux $source reverse=$reverse',
          );
        }
      }
    },
    skip: ffmpeg == null
        ? 'Set MARKCUT_FFMPEG for real codec validation'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
