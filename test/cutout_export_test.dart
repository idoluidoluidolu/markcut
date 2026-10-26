// 去背走 FFmpeg 匯出（Android 唯一的路；iOS 原生失敗時的保底）：
//   1. 去背的片段開一路遮罩串流（gray 原始檔、每一格輸出畫面一張），
//      畫面先移到片段時間再 alphamerge；暫存檔交給呼叫端收
//   2. 背景：透明（透出下層）／純色（drawbox 鋪滿自己的框）／模糊（gblur）
//   3. 遮罩檔讀不到就整張匯出（不讓整趟失敗）；沒開的片段照舊
//   4. 去背片段每 15 秒切一段，遮罩串流的暫存檔才不會太大
//   5. 真 FFmpeg（設 MARKCUT_FFMPEG）：遮罩那一側跟沒去背的一模一樣、
//      另一側是背景；遮罩跟著時間換邊（含修剪、位移、變速）
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/cutout_mask.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/video_processor.dart';

/// 32×18 的遮罩檔：第 i 格（i/30 秒）前 [flip] 格人在左半，之後換到右半
void _writeMask(String path, {int frames = 90, int flip = 45}) {
  final w = CutoutMaskWriter(path, 32, 18);
  for (var i = 0; i < frames; i++) {
    final m = Uint8List(32 * 18);
    for (var y = 0; y < 18; y++) {
      for (var x = 0; x < 32; x++) {
        final left = x < 16;
        m[y * 32 + x] = (i < flip ? left : !left) ? 255 : 0;
      }
    }
    w.add(i / 30, m);
  }
  w.close();
}

ExportSpec _spec({
  required String video,
  required String? mask,
  ClipCutout? cut,
  double trimStart = 0,
  double trimEnd = 3,
  double offset = 0,
  double speed = 1,
  double duration = 3,
}) {
  debugPrimeProbe(video, hasAudio: false, fps: 30, dispW: 320, dispH: 180);
  final c = TimelineClip(
    id: 1,
    sourceIndex: 0,
    trimStart: trimStart,
    trimEnd: trimEnd,
    offset: offset,
    track: 0,
    speed: speed,
    cutout: cut,
  );
  return ExportSpec(
    sources: [
      MediaSource(
        path: video,
        name: 'v',
        kind: ClipKind.video,
        duration: duration,
        w: 320,
        h: 180,
        cutMask: mask,
      ),
    ],
    clips: [c],
    timelineDuration: c.end,
    speed: 1,
    watermarkPng: null,
    outW: 320,
    outH: 180,
    fps: 30,
  );
}

String _filter(List<String> args) => args[args.indexOf('-filter_complex') + 1];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String mask;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('markcut_cutx_');
    debugMosaicCmdDir = dir.path;
    mask = '${dir.path}/m.mcmk';
    _writeMask(mask);
  });
  tearDown(() async {
    debugMosaicCmdDir = null;
    await dir.delete(recursive: true);
  });

  test('去背片段：遮罩串流一路輸入、alphamerge，暫存檔交給呼叫端', () async {
    final temps = <String>[];
    final args = await debugBuildArguments(
      _spec(video: 'v.mp4', mask: mask, cut: ClipCutout()),
      'out.mp4',
      tempFiles: temps,
    );
    final f = _filter(args);
    expect(f, contains('alphamerge'));
    expect(f, contains('[1:v]setpts=PTS-STARTPTS+0.000/TB'));
    expect(f, isNot(contains('drawbox')));
    final at = args.indexOf('rawvideo');
    expect(args.sublist(at - 1, at + 9), [
      '-f',
      'rawvideo',
      '-pix_fmt',
      'gray',
      '-s',
      '32x18',
      '-framerate',
      '30.000',
      '-i',
      temps.single,
    ]);
    // 3 秒、30fps：91 格（多一格墊尾巴），每格 32×18
    expect(File(temps.single).lengthSync(), 91 * 32 * 18);
  });

  test('背景：純色用 drawbox 鋪滿自己的框、模糊用 gblur（長邊 2%）', () async {
    final color = _filter(
      await debugBuildArguments(
        _spec(
          video: 'v.mp4',
          mask: mask,
          cut: ClipCutout(bg: CutoutBg.color, color: 0xFF00B140),
        ),
        'out.mp4',
      ),
    );
    expect(color, contains('drawbox=x=0:y=0:w=iw:h=ih:color=0x00b140@1.0'));
    final blur = _filter(
      await debugBuildArguments(
        _spec(
          video: 'v.mp4',
          mask: mask,
          cut: ClipCutout(bg: CutoutBg.blur),
        ),
        'out.mp4',
      ),
    );
    expect(blur, contains('gblur=sigma=6.400'));
  });

  test('遮罩檔讀不到、或沒開去背：照舊整張（不開遮罩輸入）', () async {
    for (final s in [
      _spec(video: 'v.mp4', mask: '${dir.path}/none.mcmk', cut: ClipCutout()),
      _spec(video: 'v.mp4', mask: mask),
    ]) {
      final args = await debugBuildArguments(s, 'out.mp4');
      expect(_filter(args), isNot(contains('alphamerge')));
      expect(args, isNot(contains('rawvideo')));
    }
  });

  test('去背片段每 15 秒切一段（遮罩串流的暫存檔才不會太大）', () {
    final b = debugSegmentBounds(
      _spec(
        video: 'v.mp4',
        mask: mask,
        cut: ClipCutout(),
        trimEnd: 40,
        duration: 40,
      ),
    );
    expect(b, [0, 15, 30, 40]);
    // 沒開去背不多切
    expect(
      debugSegmentBounds(
        _spec(video: 'v.mp4', mask: mask, trimEnd: 40, duration: 40),
      ),
      [0, 40],
    );
  });

  test('分段渲染：遮罩串流只產這一段（片段時間從這一段的開頭算）', () async {
    final temps = <String>[];
    final args = await debugBuildArguments(
      _spec(video: 'v.mp4', mask: mask, cut: ClipCutout()),
      'seg.mp4',
      tempFiles: temps,
      winStart: 1,
      winEnd: 2,
      videoOnly: true,
    );
    expect(_filter(args), contains('setpts=PTS-STARTPTS+1.000/TB'));
    expect(File(temps.single).lengthSync(), 31 * 32 * 18);
  });

  final ffmpeg = Platform.environment['MARKCUT_FFMPEG'];
  test(
    '真 FFmpeg：人那一側跟沒去背的一樣、另一側是背景；遮罩跟著時間換邊',
    () async {
      Future<void> run(List<String> args) async {
        final r = await Process.run(ffmpeg!, [
          '-hide_banner',
          '-loglevel',
          'error',
          ...args,
        ]);
        expect(r.exitCode, 0, reason: r.stderr.toString());
      }

      Future<Uint8List> frame(String path, int n) async {
        final r = await Process.run(ffmpeg!, [
          '-hide_banner',
          '-loglevel',
          'error',
          '-i',
          path,
          '-vf',
          'select=eq(n\\,$n)',
          '-frames:v',
          '1',
          '-f',
          'rawvideo',
          '-pix_fmt',
          'rgb24',
          '-',
        ], stdoutEncoding: null);
        expect(r.exitCode, 0, reason: r.stderr.toString());
        final bytes = Uint8List.fromList(r.stdout as List<int>);
        expect(bytes.length, 320 * 180 * 3);
        return bytes;
      }

      // 平台的編碼器換成無損（同 brush_mosaic_export_test），濾鏡圖原封不動
      List<String> desktop(List<String> args) {
        final out = <String>[];
        const drop = {'-b:v', '-maxrate', '-bufsize', '-b:a', '-movflags'};
        for (var i = 0; i < args.length; i++) {
          if (drop.contains(args[i]) || args[i] == '-hwaccel') {
            i++;
            continue;
          }
          out.add(switch (args[i]) {
            'h264_mediacodec' || 'h264_videotoolbox' => 'ffv1',
            'nv12' => 'yuv420p',
            _ => args[i],
          });
        }
        return out;
      }

      final src = '${dir.path}/src.nut';
      await run([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=320x180:rate=30:duration=3,noise=alls=40:allf=t+u',
        '-c:v',
        'ffv1',
        src,
      ]);

      int diff(Uint8List a, Uint8List b, int x, int y) {
        final i = (y * 320 + x) * 3;
        return (a[i] - b[i]).abs() +
            (a[i + 1] - b[i + 1]).abs() +
            (a[i + 2] - b[i + 2]).abs();
      }

      /// [keepLeft]：人在左半（右半是背景）；交界 ±25px 不比（遮罩 32 寬
      /// 拉到 320 是內插的漸層）。印出平均差與偏差，實機回報時好對照
      void check(
        Uint8List got,
        Uint8List ref,
        bool keepLeft,
        List<int> bg,
        String why,
      ) {
        var sumP = 0, nP = 0, sumB = 0, nB = 0, worstB = 0, worstP = 0;
        final signed = [0, 0, 0];
        for (var y = 0; y < 180; y += 2) {
          for (var x = 0; x < 320; x += 2) {
            if ((x - 160).abs() < 25) continue;
            final person = (x < 160) == keepLeft;
            if (person) {
              final d = diff(got, ref, x, y);
              sumP += d;
              nP++;
              if (d > worstP) worstP = d;
              final i = (y * 320 + x) * 3;
              for (var k = 0; k < 3; k++) {
                signed[k] += got[i + k] - ref[i + k];
              }
            } else {
              final i = (y * 320 + x) * 3;
              final d =
                  (got[i] - bg[0]).abs() +
                  (got[i + 1] - bg[1]).abs() +
                  (got[i + 2] - bg[2]).abs();
              sumB += d;
              nB++;
              if (d > worstB) worstB = d;
            }
          }
        }
        final bias = [for (final s in signed) (s / nP).toStringAsFixed(2)];
        // ignore: avoid_print
        print(
          '$why：人 平均差 ${(sumP / nP).toStringAsFixed(2)} 最大 $worstP '
          '偏差 RGB $bias｜背景 平均 ${(sumB / nB).toStringAsFixed(2)} 最大 $worstB',
        );
        // 畫面一路維持 YUV（不多轉 RGBA），人那一側實測逐像素一樣；
        // 純色背景經 RGB→YUV→RGB 有 1 階捨入
        expect(sumP / nP, lessThan(1), reason: '$why：人那一側要跟原片一樣');
        expect(sumB / nB, lessThan(6), reason: '$why：背景那一側要是背景');
        expect(worstB, lessThan(12), reason: '$why：背景那一側不能漏原片');
      }

      final refOut = '${dir.path}/ref.nut';
      await run(
        desktop(
          await debugBuildArguments(_spec(video: src, mask: mask), refOut),
        ),
      );

      // 1. 透明（下面是黑畫布）：第 30 格人在左、第 60 格換到右
      final out = '${dir.path}/out.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(video: src, mask: mask, cut: ClipCutout()),
            out,
          ),
        ),
      );
      check(await frame(out, 30), await frame(refOut, 30), true, [
        0,
        0,
        0,
      ], '透明 1 秒');
      check(await frame(out, 60), await frame(refOut, 60), false, [
        0,
        0,
        0,
      ], '透明 2 秒');

      // 2. 純色背景：背景那一側是綠幕綠
      final green = '${dir.path}/green.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(
              video: src,
              mask: mask,
              cut: ClipCutout(bg: CutoutBg.color, color: 0xFF00B140),
            ),
            green,
          ),
        ),
      );
      check(await frame(green, 30), await frame(refOut, 30), true, [
        0,
        177,
        64,
      ], '純色');

      // 3. 修剪＋位移：片段從素材 1 秒開始、放在時間軸 0.5 秒。輸出 0.6 秒
      //（第 18 格）＝素材 1.1 秒（人在左）；1.0 秒（第 30 格）＝素材 1.5 秒
      //（換到右）；0.3 秒還沒開始＝整片黑
      final shifted = '${dir.path}/shift.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(
              video: src,
              mask: mask,
              cut: ClipCutout(),
              trimStart: 1,
              trimEnd: 2.5,
              offset: 0.5,
            ),
            shifted,
          ),
        ),
      );
      final refShift = '${dir.path}/refshift.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(
              video: src,
              mask: mask,
              trimStart: 1,
              trimEnd: 2.5,
              offset: 0.5,
            ),
            refShift,
          ),
        ),
      );
      check(await frame(shifted, 18), await frame(refShift, 18), true, [
        0,
        0,
        0,
      ], '位移 0.6 秒');
      check(await frame(shifted, 31), await frame(refShift, 31), false, [
        0,
        0,
        0,
      ], '位移 1.03 秒');
      final early = await frame(shifted, 9);
      expect(early.every((v) => v < 8), isTrue, reason: '片段開始前是黑畫布');

      // 4. 兩倍速：輸出 0.5 秒＝素材 1 秒（左）、輸出 1.0 秒＝素材 2 秒（右）
      final fast = '${dir.path}/fast.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(video: src, mask: mask, cut: ClipCutout(), speed: 2),
            fast,
          ),
        ),
      );
      final refFast = '${dir.path}/reffast.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(video: src, mask: mask, speed: 2),
            refFast,
          ),
        ),
      );
      check(await frame(fast, 15), await frame(refFast, 15), true, [
        0,
        0,
        0,
      ], '兩倍速 0.5 秒');
      check(await frame(fast, 31), await frame(refFast, 31), false, [
        0,
        0,
        0,
      ], '兩倍速 1.03 秒');

      // 5. 模糊背景：人那一側照舊；背景那一側是原片糊掉——不是黑的，
      //（素材加了雜訊）也跟原片差很多
      final blur = '${dir.path}/blur.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(
              video: src,
              mask: mask,
              cut: ClipCutout(bg: CutoutBg.blur),
            ),
            blur,
          ),
        ),
      );
      final gotB = await frame(blur, 30);
      final refB = await frame(refOut, 30);
      var sumKeep = 0, nKeep = 0, sumBg = 0, sumLum = 0, nBg = 0;
      for (var y = 0; y < 180; y += 2) {
        for (var x = 0; x < 320; x += 2) {
          if ((x - 160).abs() < 25) continue;
          final i = (y * 320 + x) * 3;
          if (x < 160) {
            sumKeep += diff(gotB, refB, x, y);
            nKeep++;
          } else {
            sumBg += diff(gotB, refB, x, y);
            sumLum += gotB[i] + gotB[i + 1] + gotB[i + 2];
            nBg++;
          }
        }
      }
      expect(sumKeep / nKeep, lessThan(1), reason: '模糊：人那一側照舊');
      expect(sumLum / nBg, greaterThan(60), reason: '模糊：背景不是黑的');
      expect(sumBg / nBg, greaterThan(15), reason: '模糊：背景要糊掉（跟原片不同）');
    },
    skip: ffmpeg == null ? '設 MARKCUT_FFMPEG 才跑真 FFmpeg' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
