import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/video_engine_io.dart';
import 'package:markcut/services/video_processor.dart';

/// 三段影片＋一段疊在中間的文字，跟使用者回報閃退的那種專案同形狀
ExportSpec _spec({
  bool hdr = false,
  bool audio = true,
  bool text = false,
  double fadeOut = 0,
}) {
  final sources = <MediaSource>[
    for (var i = 0; i < 3; i++)
      MediaSource(
        path: 'c$i.mp4',
        name: 'c$i',
        kind: ClipKind.video,
        duration: 2,
        w: 1080,
        h: 1920,
      ),
    if (text)
      MediaSource(
        path: '',
        name: '字',
        kind: ClipKind.text,
        duration: 3600,
        textStyle: TextMark(text: '字'),
      ),
  ];
  final clips = <TimelineClip>[
    for (var i = 0; i < 3; i++)
      TimelineClip(
        id: i,
        sourceIndex: i,
        trimStart: 0,
        trimEnd: 2,
        offset: i * 2.0,
        track: 0,
        fadeOut: i == 0 ? fadeOut : 0,
      ),
    if (text)
      TimelineClip(
        id: 9,
        sourceIndex: 3,
        trimStart: 0,
        trimEnd: 2,
        offset: 1, // 跨在第一段與第二段的交界上
        track: 1,
      ),
  ];
  for (var i = 0; i < sources.length; i++) {
    if (sources[i].kind != ClipKind.video) continue;
    debugPrimeProbe(
      sources[i].path,
      hasAudio: audio,
      fps: 30,
      hdr: hdr,
      trc: hdr ? 'arib-std-b67' : '',
      dispW: 1080,
      dispH: 1920,
    );
  }
  debugZscaleAvailable = true;
  return ExportSpec(
    sources: sources,
    clips: clips,
    timelineDuration: 6,
    speed: 1,
    watermarkPng: null,
    outW: 1080,
    outH: 1920,
  );
}

void main() {
  test('切點：切在每個素材的頭尾，太碎的合併掉', () {
    expect(debugSegmentBounds(_spec()), [0.0, 2.0, 4.0, 6.0]);
    // 疊在交界上的文字會多切兩刀（1 秒與 3 秒）
    expect(debugSegmentBounds(_spec(text: true)), [0.0, 1.0, 2.0, 3.0, 4.0, 6.0]);
  });

  test('每一段只組這一段看得到的圖層', () async {
    final spec = _spec();
    final first = await debugBuildCommand(
      spec,
      'seg0.mp4',
      winStart: 0,
      winEnd: 2,
      videoOnly: true,
    );
    // 第一段只該有第一支素材
    expect(first, contains('-i "c0.mp4"'));
    expect(first, isNot(contains('c1.mp4')));
    expect(first, isNot(contains('c2.mp4')));
    // 分段時聲音不在這一趟做
    expect(first, contains('-an'));
    expect(first, isNot(contains('amix')));
    // 長度就是這一段的長度
    expect(first, contains('-t 2.000'));

    final mid = await debugBuildCommand(
      spec,
      'seg1.mp4',
      winStart: 2,
      winEnd: 4,
      videoOnly: true,
    );
    expect(mid, contains('-i "c1.mp4"'));
    expect(mid, isNot(contains('c0.mp4')));
    // 第二段的圖層從 0 秒開始畫（段內時間），不是從 2 秒
    expect(mid, contains('gte(t\\,0.000)'));
  });

  test('跨段的素材：時間往前挪，淡化用片段自己的時間', () async {
    // 文字從 1 秒跨到 3 秒，會被切成 [1,2) 與 [2,3) 兩段
    final spec = _spec(text: true, fadeOut: 0.5);
    final seg = await debugBuildCommand(
      spec,
      'seg.mp4',
      winStart: 2,
      winEnd: 3,
      videoOnly: true,
      overlayFiles: const {9: 'txt.png'},
    );
    // 文字在這一段裡是「從自己的第 1 秒開始播」
    expect(seg, contains('trim=start=1.000:end=2.000'));
    // 淡出的起點是片段自己的時間（2 秒長、淡 0.5 秒 → 1.5），
    // 不是輸出時間 1.5+offset
    final fade = RegExp(r'fade=t=out:st=([0-9.]+)').firstMatch(
      await debugBuildCommand(
        spec,
        'seg.mp4',
        winStart: 0,
        winEnd: 1,
        videoOnly: true,
        overlayFiles: const {9: 'txt.png'},
      ),
    );
    expect(fade, isNotNull);
    expect(double.parse(fade!.group(1)!), closeTo(1.5, 0.001));
  });

  test('沒有分段時（單段專案）聲音照舊在同一趟做', () async {
    final spec = ExportSpec(
      sources: [
        MediaSource(
          path: 'c0.mp4',
          name: 'c0',
          kind: ClipKind.video,
          duration: 2,
          w: 1080,
          h: 1920,
        ),
      ],
      clips: [
        TimelineClip(
          id: 0,
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 2,
          offset: 0,
          track: 0,
        ),
      ],
      timelineDuration: 2,
      speed: 1,
      watermarkPng: null,
      outW: 1080,
      outH: 1920,
    );
    debugPrimeProbe('c0.mp4', hasAudio: true, fps: 30);
    expect(debugSegmentBounds(spec), [0.0, 2.0]);
    final cmd = await debugBuildCommand(spec, 'out.mp4');
    expect(cmd, contains('-c:a aac'));
  });

  test('配音那一趟：畫面直接 copy，只有聲音在跑', () async {
    final spec = _spec();
    final cmd = await debugBuildAudioMux(spec, 'joined.mp4', 'out.mp4');
    expect(cmd, isNotNull);
    expect(cmd!, contains('-map 0:v -c:v copy'));
    expect(cmd, contains('amix=inputs=3'));
    expect(cmd, contains('adelay=4000'));
    // 沒有任何一路聲音時不做這一趟
    expect(await debugBuildAudioMux(_spec(audio: false), 'j.mp4', 'o.mp4'),
        isNull);
  });

  /// 把指令倒出來，讓外面拿真的 ffmpeg 跑（見 scratchpad 的驗證腳本）。
  /// 只有設了 DUMP_CMDS 才寫檔，平常跑測試不留垃圾
  test('倒出指令給 ffmpeg 實測', () async {
    final out = Platform.environment['DUMP_CMDS'];
    if (out == null) return;
    final spec = _spec(hdr: true, text: true, fadeOut: 0.5);
    final bounds = debugSegmentBounds(spec);
    final cmds = <String>[];
    for (var i = 0; i < bounds.length - 1; i++) {
      cmds.add(
        await debugBuildCommand(
          spec,
          'seg$i.mp4',
          winStart: bounds[i],
          winEnd: bounds[i + 1],
          videoOnly: true,
          overlayFiles: const {9: 'txt.png'},
        ),
      );
    }
    final mux = await debugBuildAudioMux(spec, 'joined.mp4', 'final.mp4');
    File(out).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'bounds': bounds,
        'segments': cmds,
        'mux': mux,
      }),
    );
  });
}
