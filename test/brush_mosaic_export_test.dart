// 筆刷馬賽克走 FFmpeg 匯出（Android 唯一的路；iOS 原生失敗時的保底）：
//   1. 只碼筆畫：效果鋪滿筆畫的包圍盒，遮罩 PNG 經 alphaextract →
//      alphamerge 當補丁的 alpha 疊回去。以前這條完全不看筆畫，拿片段的
//      px/py/scale 碼畫面正中央一塊正方形
//   2. 範圍＝筆畫包圍盒外推半個筆刷＋柔邊（跟 iOS 的 CIMosaicSpec 同一個
//      算法），夾進畫面、對齊偶數；遮罩 PNG 也是這一塊的大小
//   3. 遮罩輸入的編號跟文字、浮水印的輸入排在一起也對得上
//   4. 分段渲染看不到的那一段、整筆拖出畫面的，不開遮罩也不組圖層
//   5. 遮罩做不出來就退回碼整個包圍盒（寧可多碼，不能漏碼）
//   6. 真 FFmpeg（設 MARKCUT_FFMPEG）：筆畫上被碼，包圍盒裡筆畫外的
//      每一個像素都跟沒碼的一模一樣；柔邊是由內往外的漸層
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/brush_mask.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/video_processor.dart';

const _stroke = [0.2, 0.3, 0.6, 0.7];

/// 320×180 的畫布：影片 0~3 秒鋪底，筆刷馬賽克（片段 2）在 0.5~2.5 秒
ExportSpec _spec({
  String video = 'v.mp4',
  List<double> stroke = _stroke,
  double brush = 0.2,
  MosaicStyle? style,
  bool mosaic = true,
  bool text = false,
}) {
  debugPrimeProbe(video, hasAudio: false, fps: 30, dispW: 320, dispH: 180);
  return ExportSpec(
    sources: [
      MediaSource(
        path: video,
        name: 'v',
        kind: ClipKind.video,
        duration: 3,
        w: 320,
        h: 180,
      ),
      MediaSource(
        path: '',
        name: '筆刷馬賽克',
        kind: ClipKind.mosaic,
        duration: 3600,
        mosaicStyle: style ?? MosaicStyle(),
        mosaicStroke: List.of(stroke),
        mosaicBrush: brush,
      ),
      if (text)
        MediaSource(path: '', name: '字', kind: ClipKind.text, duration: 3600),
    ],
    clips: [
      TimelineClip(
        id: 1,
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 3,
        offset: 0,
        track: 0,
      ),
      if (mosaic)
        TimelineClip(
          id: 2,
          sourceIndex: 1,
          trimStart: 0,
          trimEnd: 2,
          offset: 0.5,
          track: 1,
        ),
      if (text)
        TimelineClip(
          id: 3,
          sourceIndex: 2,
          trimStart: 0,
          trimEnd: 3,
          offset: 0,
          track: 2,
        ),
    ],
    timelineDuration: 3,
    speed: 1,
    watermarkPng: null,
    outW: 320,
    outH: 180,
    fps: 30,
  );
}

String _filter(List<String> args) => args[args.indexOf('-filter_complex') + 1];

/// 每個 -i 後面的檔案，照輸入編號排
List<String> _inputs(List<String> args) => [
  for (var i = 0; i + 1 < args.length; i++)
    if (args[i] == '-i') args[i + 1],
];

Future<ui.Image> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  return (await codec.getNextFrame()).image;
}

/// 遮罩某一格的 alpha
Future<int Function(double x, double y)> _alphaOf(ui.Image im) async {
  final px = (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return (x, y) => px.getUint8((y.round() * im.width + x.round()) * 4 + 3);
}

/// 點到筆畫中線（折線）的距離
double _distToStroke(ui.Offset p, List<ui.Offset> pts) {
  if (pts.length == 1) return (p - pts.first).distance;
  var best = double.infinity;
  for (var i = 0; i + 1 < pts.length; i++) {
    final a = pts[i], ab = pts[i + 1] - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = len2 == 0
        ? 0.0
        : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
    best = math.min(best, (p - (a + ab * t)).distance);
  }
  return best;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 筆刷 0.2×180＝36px（半徑 18）；中線 (64,54)→(192,126)
  // 包圍盒外推 18＋2＝20 → (44,34)~(212,146)，168×112
  test('筆畫：效果只鋪包圍盒，遮罩當 alpha 疊回去（不是正中央的方框）', () async {
    final args = await debugBuildArguments(
      _spec(),
      'out.mp4',
      maskFiles: {2: 'mask.png'},
    );
    final f = _filter(args);
    expect(_inputs(args), ['v.mp4', 'mask.png']);
    // 遮罩只要一張：image2、不 -loop
    final mi = args.indexOf('mask.png');
    expect(args.sublist(mi - 3, mi + 1), ['-f', 'image2', '-i', 'mask.png']);
    expect(
      f,
      contains(
        '[ov0]split=2[mzA1][mzB1];'
        '[mzB1]crop=168:112:44:34,scale=16:11,scale=168:112:flags=neighbor,'
        'format=yuva420p[mzE1];'
        '[1:v]alphaextract,scale=168:112[mzM1];'
        '[mzE1][mzM1]alphamerge[mzP1];'
        '[mzA1][mzP1]overlay=44:34:enable=gte(t\\,0.500)*lt(t\\,2.500):'
        'eof_action=pass[mz1]',
      ),
    );
    expect(
      f,
      isNot(contains('crop=180:180:70:0')),
      reason: '舊的錯：拿片段的 px/py/scale 碼畫面正中央一塊正方形',
    );
    expect(args[args.indexOf('-map') + 1], '[mz1]');
  });

  test('模糊、純色：同一塊、同一個遮罩，只換效果', () async {
    final blur = _filter(
      await debugBuildArguments(
        _spec(style: MosaicStyle(type: 1)),
        'out.mp4',
        maskFiles: {2: 'mask.png'},
      ),
    );
    // 縮小倍數 2＋12×0.5＝8：168/8＝21、112/8＝14
    expect(
      blur,
      contains(
        '[mzB1]crop=168:112:44:34,scale=21:14,scale=168:112:flags=bilinear,'
        'format=yuva420p[mzE1]',
      ),
    );
    final solid = _filter(
      await debugBuildArguments(
        _spec(style: MosaicStyle(type: 2, color: 0xFF112233)),
        'out.mp4',
        maskFiles: {2: 'mask.png'},
      ),
    );
    expect(
      solid,
      contains(
        '[mzB1]crop=168:112:44:34,'
        'drawbox=x=0:y=0:w=168:h=112:color=0x112233:t=fill,'
        'format=yuva420p[mzE1]',
      ),
    );
    expect(solid, contains('[mzE1][mzM1]alphamerge'));
  });

  test('柔邊：包圍盒多留柔邊的尾巴（跟 iOS 的 rect 一樣）', () async {
    // 柔邊 0.5 → 0.5×0.5×36＝9px；外推 18＋9＋2＝29 → 左上 (35,25) 捨成
    // 偶數 (34,24)，右下 (221,155) → 188×132
    final f = _filter(
      await debugBuildArguments(
        _spec(style: MosaicStyle(feather: 0.5)),
        'out.mp4',
        maskFiles: {2: 'mask.png'},
      ),
    );
    expect(f, contains('crop=188:132:34:24,'));
    expect(f, contains('alphaextract,scale=188:132[mzM1]'));
    expect(f, contains('overlay=34:24:'));
    // 柔邊在遮罩裡：效果整塊一次做足，不像方形那樣分圈
    expect(f, isNot(contains('mzA1f')));
    expect(f, isNot(contains('mzA1p')));
  });

  test('貼著畫面邊緣：夾進畫面、對齊偶數', () async {
    // 中線 (288,90)→(384,90)，外推 20 → x 268~404、y 70~110，右邊夾到 320
    final f = _filter(
      await debugBuildArguments(
        _spec(stroke: [0.9, 0.5, 1.2, 0.5]),
        'out.mp4',
        maskFiles: {2: 'mask.png'},
      ),
    );
    expect(f, contains('crop=52:40:268:70,'));
    expect(f, contains('overlay=268:70:'));
  });

  test('整筆拖出畫面：不開遮罩、不組圖層', () async {
    final args = await debugBuildArguments(
      _spec(stroke: [1.5, 0.5, 1.8, 0.5]),
      'out.mp4',
      maskFiles: {2: 'mask.png'},
    );
    expect(_inputs(args), ['v.mp4']);
    expect(_filter(args), isNot(contains('mz1')));
    expect(args[args.indexOf('-map') + 1], '[ov0]');
  });

  test('分段渲染：看不到的那一段不開遮罩；看得到的時間換成段內秒數', () async {
    final none = await debugBuildArguments(
      _spec(),
      'out.mp4',
      maskFiles: {2: 'mask.png'},
      winStart: 2.6,
      winEnd: 3,
      videoOnly: true,
    );
    expect(_inputs(none), ['v.mp4']);
    expect(_filter(none), isNot(contains('alphamerge')));

    final mid = await debugBuildArguments(
      _spec(),
      'out.mp4',
      maskFiles: {2: 'mask.png'},
      winStart: 1,
      winEnd: 2,
      videoOnly: true,
    );
    expect(_inputs(mid), ['v.mp4', 'mask.png']);
    expect(
      _filter(mid),
      contains('overlay=44:34:enable=gte(t\\,0.000)*lt(t\\,1.000):'),
    );
  });

  test('遮罩做不出來：退回碼整個包圍盒（寧可多碼）', () async {
    final args = await debugBuildArguments(_spec(), 'out.mp4');
    final f = _filter(args);
    expect(_inputs(args), ['v.mp4']);
    expect(
      f,
      contains(
        '[mzB1]crop=168:112:44:34,scale=16:11,scale=168:112:flags=neighbor'
        '[mzP1];[mzA1][mzP1]overlay=44:34:',
      ),
    );
    expect(f, isNot(contains('alphamerge')));
  });

  test('跟文字、浮水印一起：遮罩排在文字後面、浮水印前面，編號對得上', () async {
    final args = await debugBuildArguments(
      _spec(text: true),
      'out.mp4',
      wmPath: 'wm.png',
      overlayFiles: {3: 'txt.png'},
      maskFiles: {2: 'mask.png'},
    );
    final f = _filter(args);
    expect(_inputs(args), ['v.mp4', 'txt.png', 'mask.png', 'wm.png']);
    expect(f, contains('[1:v]trim='), reason: '文字是 1 號');
    expect(f, contains('[2:v]alphaextract'), reason: '遮罩是 2 號');
    expect(f, contains('[3:v]overlay='), reason: '浮水印是 3 號');
  });

  test('遮罩 PNG：大小跟濾鏡圖那一塊一樣，筆畫上 alpha 滿、外面 0', () async {
    final png = (await renderBrushMaskPng(
      _stroke,
      0.2,
      MosaicStyle(),
      320,
      180,
    ))!;
    final im = await _decode(png);
    expect((im.width, im.height), (168, 112));
    final a = await _alphaOf(im);
    // 中線上、離中線 10px（半徑 18 以內）→ 滿；離 25px → 0
    // 方向：中線 (128,72)/146.86，法線 (-0.490, 0.872)；遮罩原點 (44,34)
    ui.Offset at(double t, double d) =>
        const ui.Offset(64, 54) +
        const ui.Offset(128, 72) * t +
        const ui.Offset(-0.4903, 0.8716) * d -
        const ui.Offset(44, 34);
    for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      expect(a(at(t, 0).dx, at(t, 0).dy), 255, reason: '中線 t=$t');
    }
    expect(a(at(0.5, 10).dx, at(0.5, 10).dy), 255);
    expect(a(at(0.5, -10).dx, at(0.5, -10).dy), 255);
    expect(a(at(0.5, 25).dx, at(0.5, 25).dy), 0);
    expect(a(at(0.5, -25).dx, at(0.5, -25).dy), 0);
    // 包圍盒的角落離筆畫很遠
    expect(a(2, 2), 0);
    expect(a(165, 2), 0);
    expect(a(2, 109), 0);
  });

  test('遮罩 PNG：柔邊＝線寬先收、再暈開，邊緣是漸層', () async {
    // 柔邊 0.5 → 9px：線寬 36−9＝27（半寬 13.5）、σ＝4.5
    final png = (await renderBrushMaskPng(
      _stroke,
      0.2,
      MosaicStyle(feather: 0.5),
      320,
      180,
    ))!;
    final im = await _decode(png);
    expect((im.width, im.height), (188, 132));
    final a = await _alphaOf(im);
    ui.Offset at(double d) =>
        const ui.Offset(128, 90) +
        const ui.Offset(-0.4903, 0.8716) * d -
        const ui.Offset(34, 24);
    expect(a(at(0).dx, at(0).dy), greaterThan(240));
    final edge = a(at(13.5).dx, at(13.5).dy);
    expect(edge, inInclusiveRange(70, 185), reason: '半寬處約一半');
    expect(a(at(27).dx, at(27).dy), lessThan(10));
    // 由內往外一路變淡
    var last = 256;
    for (var d = 0.0; d <= 27; d += 3) {
      final v = a(at(d).dx, at(d).dy);
      expect(v, lessThanOrEqualTo(last), reason: 'd=$d');
      last = v;
    }
  });

  test('遮罩 PNG：單點＝一個圓；整筆在畫面外回 null', () async {
    // (160,90) 外推 20 → (140,70) 40×40
    final dot = await _decode(
      (await renderBrushMaskPng([0.5, 0.5], 0.2, MosaicStyle(), 320, 180))!,
    );
    expect((dot.width, dot.height), (40, 40));
    final a = await _alphaOf(dot);
    expect(a(20, 20), 255);
    expect(a(20 + 12, 20), 255);
    expect(a(1, 1), 0);
    expect(
      await renderBrushMaskPng(
        [1.5, 0.5, 1.8, 0.5],
        0.2,
        MosaicStyle(),
        320,
        180,
      ),
      isNull,
    );
  });

  test('包圍盒：遮罩 PNG 跟濾鏡圖用同一個 brushStrokeBox', () {
    expect(brushStrokeBox(_stroke, 0.2, MosaicStyle(), 320, 180), (
      x: 44,
      y: 34,
      w: 168,
      h: 112,
    ));
    // 奇數寬的畫布：寬度往下收成偶數、不超出畫面
    final odd = brushStrokeBox([0.95, 0.5], 0.2, MosaicStyle(), 321, 181)!;
    expect(odd.x % 2, 0);
    expect(odd.w % 2, 0);
    expect(odd.x + odd.w, lessThanOrEqualTo(321));
    expect(brushStrokeBox([0.5], 0.2, MosaicStyle(), 320, 180), isNull);
  });

  final ffmpeg = Platform.environment['MARKCUT_FFMPEG'];
  test(
    '真 FFmpeg：只有筆畫被碼，包圍盒裡筆畫外跟沒碼的一模一樣',
    () async {
      final dir = await Directory.systemTemp.createTemp('markcut_brush_');
      addTearDown(() => dir.delete(recursive: true));
      Future<void> run(List<String> args) async {
        final r = await Process.run(ffmpeg!, [
          '-hide_banner',
          '-loglevel',
          'error',
          ...args,
        ]);
        expect(r.exitCode, 0, reason: r.stderr.toString());
      }

      // 第 [n] 格的 RGB
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

      // 只換掉平台的編碼器跟封裝（跟 export_input_seek_test 同一招），
      // 濾鏡圖原封不動
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

      // 加雜訊：testsrc2 的大色塊像素化之後可能跟原圖一樣，糊沒糊分不出來
      final src = '${dir.path}/src.nut';
      await run([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=320x180:rate=30:duration=3,noise=alls=60:allf=t+u',
        '-c:v',
        'ffv1',
        src,
      ]);

      final pts = brushStrokePoints(_stroke, 320, 180);
      final box = brushStrokeBox(_stroke, 0.2, MosaicStyle(), 320, 180)!;
      int diff(Uint8List a, Uint8List b, int x, int y) {
        final i = (y * 320 + x) * 3;
        return (a[i] - b[i]).abs() +
            (a[i + 1] - b[i + 1]).abs() +
            (a[i + 2] - b[i + 2]).abs();
      }

      /// 整張比：筆畫半徑＋3px 以外（含包圍盒外）每一格都要一模一樣；
      /// 回傳筆畫半徑−3px 以內的平均差
      double check(Uint8List got, Uint8List ref, double half, String why) {
        var sum = 0, n = 0;
        for (var y = 0; y < 180; y++) {
          for (var x = 0; x < 320; x++) {
            final d = _distToStroke(ui.Offset(x + 0.5, y + 0.5), pts);
            if (d > half + 3) {
              expect(diff(got, ref, x, y), 0, reason: '$why：($x,$y) 不該被碼');
            } else if (d < half - 3) {
              sum += diff(got, ref, x, y);
              n++;
            }
          }
        }
        return sum / n;
      }

      final refOut = '${dir.path}/ref.nut';
      await run(
        desktop(
          await debugBuildArguments(_spec(video: src, mosaic: false), refOut),
        ),
      );
      final ref30 = await frame(refOut, 30);

      final styles = [
        MosaicStyle(type: 0, strength: 0.8),
        MosaicStyle(type: 1, strength: 0.8),
        MosaicStyle(type: 2, color: 0xFFFF0000),
      ];
      for (var i = 0; i < styles.length; i++) {
        final spec = _spec(video: src, style: styles[i]);
        final mask = '${dir.path}/mask_$i.png';
        await File(mask).writeAsBytes(
          (await renderBrushMaskPng(_stroke, 0.2, styles[i], 320, 180))!,
        );
        final out = '${dir.path}/out_$i.nut';
        await run(
          desktop(await debugBuildArguments(spec, out, maskFiles: {2: mask})),
        );
        // 第 30 格（1 秒，片段裡）：筆畫上被碼、外面一模一樣
        final got = await frame(out, 30);
        final inside = check(got, ref30, 18, '樣式 ${styles[i].type}');
        expect(inside, greaterThan(20), reason: '樣式 ${styles[i].type} 筆畫上要被碼');
        if (styles[i].type == 2) {
          // 純紅：中線上每一點都是紅的
          for (final t in [0.1, 0.3, 0.5, 0.7, 0.9]) {
            final p = pts[0] + (pts[1] - pts[0]) * t;
            final j = (p.dy.round() * 320 + p.dx.round()) * 3;
            expect(got[j], greaterThan(230), reason: 'R t=$t');
            expect(got[j + 1], lessThan(40), reason: 'G t=$t');
            expect(got[j + 2], lessThan(40), reason: 'B t=$t');
          }
        }
        // 第 6 格（0.2 秒，片段還沒開始）：整張沒碼
        final early = await frame(out, 6);
        final ref6 = await frame(refOut, 6);
        expect(early, ref6, reason: '樣式 ${styles[i].type}：片段外不碼');
      }

      // 分段渲染（1~2 秒那一段）：遮罩一樣只開一張、一樣貼得上
      final segRef = '${dir.path}/seg_ref.nut';
      final segOut = '${dir.path}/seg_out.nut';
      final mask0 = '${dir.path}/mask_0.png';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(video: src, mosaic: false),
            segRef,
            winStart: 1,
            winEnd: 2,
            videoOnly: true,
          ),
        ),
      );
      await run(
        desktop(
          await debugBuildArguments(
            _spec(video: src, style: styles[0]),
            segOut,
            maskFiles: {2: mask0},
            winStart: 1,
            winEnd: 2,
            videoOnly: true,
          ),
        ),
      );
      for (final n in [0, 29]) {
        final inside = check(
          await frame(segOut, n),
          await frame(segRef, n),
          18,
          '分段第 $n 格',
        );
        expect(inside, greaterThan(20), reason: '分段第 $n 格筆畫上要被碼');
      }

      // 柔邊：筆畫邊緣由內往外漸淡；暈開範圍以外一模一樣
      final soft = MosaicStyle(type: 2, color: 0xFFFF0000, feather: 0.6);
      final softMask = '${dir.path}/mask_soft.png';
      await File(
        softMask,
      ).writeAsBytes((await renderBrushMaskPng(_stroke, 0.2, soft, 320, 180))!);
      final softOut = '${dir.path}/out_soft.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(video: src, style: soft),
            softOut,
            maskFiles: {2: softMask},
          ),
        ),
      );
      final gotSoft = await frame(softOut, 30);
      // 柔邊 0.6 → 10.8px：半寬 12.6、σ 5.4，3σ 之外歸零
      check(gotSoft, ref30, 12.6 + 3 * 5.4, '柔邊');
      const mid = ui.Offset(128, 90), normal = ui.Offset(-0.4903, 0.8716);
      int at(double d) {
        final p = mid + normal * d;
        return diff(gotSoft, ref30, p.dx.round(), p.dy.round());
      }

      expect(at(0), greaterThan(at(12)), reason: '中線比半寬處紅');
      expect(at(12), greaterThan(at(20)), reason: '半寬處比外面紅');
      expect(at(20), greaterThan(0), reason: '尾巴還有一點（不是硬邊）');

      // 文字、浮水印、遮罩三種輸入一起：編號錯了的話會拿錯圖
      final txt = '${dir.path}/txt.png';
      final wm = '${dir.path}/wm.png';
      await run([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=white@0:s=320x180,format=rgba,'
            'drawbox=x=4:y=150:w=20:h=20:color=white:t=fill:replace=1',
        '-frames:v',
        '1',
        txt,
      ]);
      await run([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=white@0:s=320x180,format=rgba,'
            'drawbox=x=290:y=6:w=20:h=20:color=blue:t=fill:replace=1',
        '-frames:v',
        '1',
        wm,
      ]);
      final allOut = '${dir.path}/out_all.nut';
      await run(
        desktop(
          await debugBuildArguments(
            _spec(video: src, style: styles[2], text: true),
            allOut,
            wmPath: wm,
            overlayFiles: {3: txt},
            maskFiles: {2: '${dir.path}/mask_2.png'},
          ),
        ),
      );
      final all = await frame(allOut, 30);
      int ch(int x, int y, int c) => all[(y * 320 + x) * 3 + c];
      expect(ch(14, 160, 0), greaterThan(230), reason: '文字（白）');
      expect(ch(14, 160, 2), greaterThan(230), reason: '文字（白）');
      expect(ch(300, 16, 2), greaterThan(200), reason: '浮水印（藍）');
      expect(ch(300, 16, 0), lessThan(40), reason: '浮水印（藍）');
      final p = pts[0] + (pts[1] - pts[0]) * 0.5;
      expect(
        ch(p.dx.round(), p.dy.round(), 0),
        greaterThan(230),
        reason: '筆畫（紅）',
      );
      expect(
        ch(box.x + 2, box.y + 2, 0),
        ref30[((box.y + 2) * 320 + box.x + 2) * 3],
      );
    },
    skip: ffmpeg == null ? '設 MARKCUT_FFMPEG 才跑真 FFmpeg' : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
