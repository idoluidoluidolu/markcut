// 會動的馬賽克（影片自動找臉）走 FFmpeg 匯出時組出來的指令：
//   1. 一段一個固定大小：split → crop@名字 → 效果 → overlay@名字，
//      位置由 sendcmd 指令檔逐格搬
//   2. 指令檔的時間是這一段（分段渲染的窗）裡的秒數，位置照關鍵點內插、
//      夾在畫面裡、取偶數，沒變的格子不重寫
//   3. 橢圓＝效果後面接 geq 挖 alpha；方的沒有
//   4. 分段渲染時看不到的那一段不組
//   5. 設了 MARKCUT_FFMPEG：真的跑 FFmpeg（Android 匯出就是這條路），
//      有碼／沒碼各匯出一次逐格比：框外一個像素都不能變、框內變成色塊、
//      框跟著時間走、橢圓的四個角不碼；模糊／純色／分段／放大都要跑得過
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/video_processor.dart';

ExportSpec _spec({
  required List<double> path,
  bool oval = true,
  double scale = 1,
  String src = 'v.mp4',
  int type = 0,
  bool withMosaic = true,
}) {
  debugPrimeProbe(src, hasAudio: false, fps: 30, dispW: 320, dispH: 180);
  final clips = [
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 4,
      offset: 0,
      track: 0,
    ),
    // 馬賽克片段：時間軸 1~3 秒（關鍵點從素材 0 秒起算）
    if (withMosaic)
      TimelineClip(
        id: 2,
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 2,
        offset: 1,
        track: 1,
        scale: scale,
      ),
  ];
  return ExportSpec(
    sources: [
      MediaSource(
        path: src,
        name: 'v',
        kind: ClipKind.video,
        duration: 4,
        w: 320,
        h: 180,
      ),
      MediaSource(
        path: '',
        name: '臉 1',
        kind: ClipKind.mosaic,
        duration: 3600,
        mosaicStyle: MosaicStyle(strength: 0.85, type: type),
        mosaicPath: path,
        mosaicOval: oval,
        mosaicFace: true,
      ),
    ],
    clips: clips,
    timelineDuration: 4,
    speed: 1,
    watermarkPng: null,
    outW: 320,
    outH: 180,
    fps: 30,
  );
}

String _filter(List<String> args) => args[args.indexOf('-filter_complex') + 1];

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('markcut_mzcmd_');
    debugMosaicCmdDir = dir.path;
  });
  tearDown(() {
    debugMosaicCmdDir = null;
    dir.deleteSync(recursive: true);
  });

  // 素材 0~2 秒：從左邊走到右邊，大小不變（一段）
  final walk = [
    0.0, 0.25, 0.5, 0.2, 0.3, //
    2.0, 0.75, 0.5, 0.2, 0.3,
  ];

  test('一段：sendcmd → crop@ → 像素化 → 橢圓 alpha → overlay@', () async {
    final args = await debugBuildArguments(_spec(path: walk), 'out.mp4');
    final f = _filter(args);
    expect(f, contains('sendcmd=f='));
    expect(f, contains('crop@mz1s0c=w=64:h=54:'));
    expect(f, contains('scale=9:8,scale=64:54:flags=neighbor'));
    expect(f, contains('geq=lum=p(X\\,Y)'), reason: '橢圓要挖 alpha');
    expect(f, contains('overlay@mz1s0o='));
    // 到片段結尾就停（最後一點之後那半格不出片段）
    expect(f, contains('enable=gte(t\\,1.000)*lt(t\\,3.000)'));

    final files = dir.listSync().whereType<File>().toList();
    expect(files.length, 1, reason: '一段一個指令檔');
    final lines = files.single.readAsLinesSync();
    // 第一格：素材 0 秒，中心 0.25*320=80 → 左上 80-32=48；y＝90-27=63 → 取偶數 62
    expect(
      lines.first,
      startsWith('1.000000 crop@mz1s0c x 48, crop@mz1s0c y 62,'),
    );
    expect(lines.first, contains('overlay@mz1s0o x 48, overlay@mz1s0o y 62;'));
    // 中間：素材 1 秒，中心 0.5*320=160 → 128
    expect(
      lines.any((l) => l.startsWith('2.000000') && l.contains('x 128,')),
      isTrue,
    );
    // 位置沒變的格子不重寫（取偶數後，每格移動 2.67px → 不會每格都變；
    // 但總數一定不超過格數）
    expect(lines.length, lessThanOrEqualTo(61));
  });

  test('片段的 scale（捏合／縮放滑桿）乘在臉框上，中心不動', () async {
    final args = await debugBuildArguments(
      _spec(path: walk, scale: 1.5),
      'out.mp4',
    );
    // 0.2×1.5×320＝96；0.3×1.5×180＝81 → 取偶數 80
    expect(_filter(args), contains('crop@mz1s0c=w=96:h=80:'));
    final lines = dir.listSync().whereType<File>().single.readAsLinesSync();
    // 中心照舊 (80, 90)：左上 80-48＝32、90-40＝50
    expect(
      lines.first,
      startsWith('1.000000 crop@mz1s0c x 32, crop@mz1s0c y 50,'),
    );
  });

  test('方的：沒有 geq', () async {
    final args = await debugBuildArguments(
      _spec(path: walk, oval: false),
      'out.mp4',
    );
    expect(_filter(args), isNot(contains('geq=')));
  });

  test('大小差很多＝兩段，各自一個 crop／overlay', () async {
    final grow = [
      0.0, 0.5, 0.5, 0.2, 0.3, //
      1.0, 0.5, 0.5, 0.2, 0.3,
      1.0, 0.5, 0.5, 0.4, 0.6,
      2.0, 0.5, 0.5, 0.4, 0.6,
    ];
    final args = await debugBuildArguments(_spec(path: grow), 'out.mp4');
    final f = _filter(args);
    expect(f, contains('crop@mz1s0c=w=64:h=54:'));
    expect(f, contains('crop@mz1s1c=w=128:h=108:'));
    expect(dir.listSync().whereType<File>().length, 2);
  });

  test('分段渲染：看不到的那一段不組，指令時間是窗裡的秒數', () async {
    final args = await debugBuildArguments(
      _spec(path: walk),
      'out.mp4',
      winStart: 2,
      winEnd: 4,
    );
    final f = _filter(args);
    expect(f, contains('enable=gte(t\\,0.000)*lt(t\\,1.000)'));
    final lines = dir.listSync().whereType<File>().single.readAsLinesSync();
    expect(lines.first, startsWith('0.000000 crop@mz1s0c x 128,'));

    final none = await debugBuildArguments(
      _spec(path: walk),
      'out.mp4',
      winStart: 3.5,
      winEnd: 4,
    );
    expect(_filter(none), isNot(contains('sendcmd')));
  });

  final ffmpeg = Platform.environment['MARKCUT_FFMPEG'];
  test(
    '真 FFmpeg：框外不變、框內色塊、跟著走、橢圓四角不碼，各種樣式都跑得過',
    () async {
      const ow = 320, oh = 180;
      Future<ProcessResult> run(List<String> args, {bool bytes = false}) async {
        final r = await Process.run(ffmpeg!, [
          '-hide_banner',
          '-loglevel',
          'error',
          ...args,
        ], stdoutEncoding: bytes ? null : systemEncoding);
        expect(r.exitCode, 0, reason: '${r.stderr}\n${args.join(' ')}');
        return r;
      }

      // 雜訊很重的素材：原畫面幾乎沒有相鄰兩點一樣，色塊一眼就分得出來
      final src = '${dir.path}${Platform.pathSeparator}noisy.mp4';
      await run([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=${ow}x$oh:rate=30:duration=4,noise=alls=60:allf=t+u',
        '-c:v',
        'libx264',
        '-crf',
        '12',
        '-g',
        '30',
        '-pix_fmt',
        'yuv420p',
        src,
      ]);

      // 平台的硬體編碼器換成無損（ffv1），其他（濾鏡圖、時間）照 App 原樣
      List<String> desktop(List<String> args) {
        final out = <String>[];
        const drop = {'-b:v', '-maxrate', '-bufsize', '-movflags', '-hwaccel'};
        for (var i = 0; i < args.length; i++) {
          if (drop.contains(args[i])) {
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

      var n = 0;
      Future<String> export(
        ExportSpec spec, {
        double win0 = 0,
        double? win1,
      }) async {
        final out = '${dir.path}${Platform.pathSeparator}out${n++}.nut';
        await run(
          desktop(
            await debugBuildArguments(spec, out, winStart: win0, winEnd: win1),
          ),
        );
        return out;
      }

      Future<Uint8List> luma(String file, double t) async {
        final r = await run([
          '-i',
          file,
          '-ss',
          t.toStringAsFixed(3),
          '-frames:v',
          '1',
          '-f',
          'rawvideo',
          '-pix_fmt',
          'gray',
          '-',
        ], bytes: true);
        final b = Uint8List.fromList(r.stdout as List<int>);
        expect(b.length, ow * oh);
        return b;
      }

      // 有碼 vs 沒碼：哪些像素變了
      ({int count, double cx, double cy, int l, int t, int r, int b}) changed(
        Uint8List a,
        Uint8List z,
      ) {
        var count = 0;
        var sx = 0.0, sy = 0.0;
        var l = ow, t = oh, r = -1, b = -1;
        for (var y = 0; y < oh; y++) {
          for (var x = 0; x < ow; x++) {
            if (a[y * ow + x] == z[y * ow + x]) continue;
            count++;
            sx += x;
            sy += y;
            if (x < l) l = x;
            if (x > r) r = x;
            if (y < t) t = y;
            if (y > b) b = y;
          }
        }
        return (
          count: count,
          cx: count == 0 ? -1 : sx / count,
          cy: count == 0 ? -1 : sy / count,
          l: l,
          t: t,
          r: r,
          b: b,
        );
      }

      // 一塊範圍裡左右相鄰兩點一樣的比例（色塊＝很高、雜訊原畫面＝很低）
      double flat(Uint8List a, int l, int t, int r, int b) {
        var same = 0, all = 0;
        for (var y = t; y <= b; y++) {
          for (var x = l; x < r; x++) {
            all++;
            if (a[y * ow + x] == a[y * ow + x + 1]) same++;
          }
        }
        return same / all;
      }

      final shots = Platform.environment['MARKCUT_SHOT_OUT'];
      Future<void> shot(String file, double t, String name) async {
        if (shots == null || shots.isEmpty) return;
        Directory(shots).createSync(recursive: true);
        await run([
          '-y',
          '-i',
          file,
          '-ss',
          t.toStringAsFixed(3),
          '-frames:v',
          '1',
          '$shots${Platform.pathSeparator}$name',
        ]);
      }

      // ── 像素化＋橢圓（找臉的預設）──
      final ref = await export(_spec(path: walk, src: src, withMosaic: false));
      final oval = await export(_spec(path: walk, src: src));
      await shot(oval, 1.5, 'ff_oval_1.5s.png');
      await shot(oval, 2.5, 'ff_oval_2.5s.png');
      for (final t in [0.5, 3.5]) {
        expect(
          changed(await luma(oval, t), await luma(ref, t)).count,
          0,
          reason: '$t 秒不在片段裡，一個像素都不能動',
        );
      }
      // 1.5 秒：中心 (120, 90)、框 64×54 → 左上 (88, 62)
      // 2.5 秒：中心 (200, 90) → 左上 (168, 62)
      for (final (t, x0) in [(1.5, 88), (2.5, 168)]) {
        final a = await luma(oval, t), z = await luma(ref, t);
        final d = changed(a, z);
        expect(d.l, greaterThanOrEqualTo(x0), reason: '$t 秒：框外左邊被動到');
        expect(d.r, lessThan(x0 + 64), reason: '$t 秒：框外右邊被動到');
        expect(d.t, greaterThanOrEqualTo(62), reason: '$t 秒：框外上面被動到');
        expect(d.b, lessThan(62 + 54), reason: '$t 秒：框外下面被動到');
        expect(d.cx, closeTo(x0 + 32, 4), reason: '$t 秒：框沒跟著臉走');
        expect(d.count, greaterThan(64 * 54 * 0.5), reason: '$t 秒：框裡沒碼到');
        // 中間那一塊是色塊、原畫面是雜訊
        final (cl, ct) = (x0 + 16, 62 + 14);
        expect(flat(a, cl, ct, cl + 32, ct + 26), greaterThan(0.7));
        expect(flat(z, cl, ct, cl + 32, ct + 26), lessThan(0.3));
        // 橢圓：四個角落（各 5×5）不碼
        for (final (cx, cy) in [
          (x0, 62),
          (x0 + 59, 62),
          (x0, 62 + 49),
          (x0 + 59, 62 + 49),
        ]) {
          for (var y = cy; y < cy + 5; y++) {
            for (var x = cx; x < cx + 5; x++) {
              expect(
                a[y * ow + x],
                z[y * ow + x],
                reason: '$t 秒：橢圓的角 ($x,$y) 被碼了',
              );
            }
          }
        }
      }

      // ── 方的：角落也碼 ──
      final square = await export(_spec(path: walk, src: src, oval: false));
      {
        final a = await luma(square, 1.5), z = await luma(ref, 1.5);
        final d = changed(a, z);
        expect(d.l, 88);
        expect(d.t, greaterThanOrEqualTo(62));
        expect(d.r, lessThan(88 + 64));
        var cornerChanged = 0;
        for (var y = 62; y < 67; y++) {
          for (var x = 88; x < 93; x++) {
            if (a[y * ow + x] != z[y * ow + x]) cornerChanged++;
          }
        }
        expect(cornerChanged, greaterThan(10), reason: '方的角落要碼');
      }

      // ── 模糊（橢圓）、純色（方）：濾鏡圖要跑得過，範圍一樣只在框裡 ──
      final blur = await export(_spec(path: walk, src: src, type: 1));
      {
        final d = changed(await luma(blur, 1.5), await luma(ref, 1.5));
        expect(d.l, greaterThanOrEqualTo(88));
        expect(d.r, lessThan(88 + 64));
        expect(d.count, greaterThan(64 * 54 * 0.5));
      }
      final solid = await export(
        _spec(path: walk, src: src, type: 2, oval: false),
      );
      {
        final a = await luma(solid, 1.5);
        final inside = {
          for (var y = 64; y < 62 + 52; y++)
            for (var x = 90; x < 88 + 62; x++) a[y * ow + x],
        };
        expect(inside.length, 1, reason: '純色遮蓋要整塊一個顏色');
      }

      // ── 放大 1.5 倍：96×80，中心不動 ──
      final big = await export(_spec(path: walk, src: src, scale: 1.5));
      {
        final d = changed(await luma(big, 1.5), await luma(ref, 1.5));
        expect(d.cx, closeTo(120, 4));
        expect(d.r - d.l + 1, inInclusiveRange(80, 96));
        expect(d.b - d.t + 1, inInclusiveRange(66, 80));
      }

      // ── 分段渲染（窗 2~4 秒）：窗裡 0.5 秒＝時間軸 2.5 秒 ──
      final refWin = await export(
        _spec(path: walk, src: src, withMosaic: false),
        win0: 2,
        win1: 4,
      );
      final win = await export(_spec(path: walk, src: src), win0: 2, win1: 4);
      {
        final d = changed(await luma(win, 0.5), await luma(refWin, 0.5));
        expect(d.cx, closeTo(200, 4), reason: '分段渲染的指令時間錯了');
        expect(
          changed(await luma(win, 1.5), await luma(refWin, 1.5)).count,
          0,
          reason: '時間軸 3.5 秒已經過了片段結尾',
        );
      }

      // ── 大小變一次（兩段）：前段 64×54、後段 128×108 ──
      final grow = await export(
        _spec(
          path: [
            0.0, 0.5, 0.5, 0.2, 0.3, //
            1.0, 0.5, 0.5, 0.2, 0.3,
            1.0, 0.5, 0.5, 0.4, 0.6,
            2.0, 0.5, 0.5, 0.4, 0.6,
          ],
          src: src,
          oval: false,
        ),
      );
      await shot(grow, 2.5, 'ff_grow_2.5s.png');
      for (final (t, w, h) in [(1.5, 64, 54), (2.5, 128, 108)]) {
        final d = changed(await luma(grow, t), await luma(ref, t));
        expect(d.r - d.l + 1, inInclusiveRange(w - 4, w), reason: '$t 秒的寬');
        expect(d.b - d.t + 1, inInclusiveRange(h - 4, h), reason: '$t 秒的高');
      }
    },
    skip: ffmpeg == null ? '設 MARKCUT_FFMPEG（ffmpeg 執行檔）才跑真匯出' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
