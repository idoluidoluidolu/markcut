// 會動的馬賽克（影片自動找臉）走 FFmpeg 匯出時組出來的指令：
//   1. 一段一個固定大小：split → crop@名字 → 效果 → overlay@名字，
//      位置由 sendcmd 指令檔逐格搬
//   2. 指令檔的時間是這一段（分段渲染的窗）裡的秒數，位置照關鍵點內插、
//      夾在畫面裡、取偶數，沒變的格子不重寫
//   3. 橢圓＝效果後面接 geq 挖 alpha；方的沒有
//   4. 分段渲染時看不到的那一段不組
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/video_processor.dart';

ExportSpec _spec({
  required List<double> path,
  bool oval = true,
  double scale = 1,
}) {
  debugPrimeProbe('v.mp4', hasAudio: false, fps: 30, dispW: 320, dispH: 180);
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
        path: 'v.mp4',
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
        mosaicStyle: MosaicStyle(strength: 0.85),
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
}
