import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/video_processor.dart';

/// 倒轉片段先倒成暫存檔、再用新的來源／片段重建 spec——重建必須把
/// 其他每一個欄位原封不動帶過去。以前手抄建構子漏了 hdr／fps／gif，
/// 有倒轉片段的 HDR 專案匯出來變 SDR、GIF 匯出來變影片
void main() {
  test('ExportSpec.copyWith 只換來源／片段，其餘欄位一個都不掉', () {
    final srcA = MediaSource(
      path: 'a.mov',
      name: 'a',
      kind: ClipKind.video,
      duration: 3,
      w: 1920,
      h: 1080,
    );
    final srcB = MediaSource(
      path: 'b.mov',
      name: 'b',
      kind: ClipKind.video,
      duration: 2,
      w: 1920,
      h: 1080,
    );
    final wm = Uint8List.fromList([1, 2, 3]);
    final ov = {7: Uint8List.fromList([9])};
    final orig = ExportSpec(
      sources: [srcA],
      clips: const [],
      timelineDuration: 12.5,
      speed: 1.5,
      watermarkPng: wm,
      outW: 1080,
      outH: 1920,
      wmStart: 1,
      wmEnd: 9,
      wmAnimation: WmAnimation.marquee,
      wmSpeed: 2,
      wmRange: 0.7,
      overlayPngs: ov,
      crf: 20,
      fps: 60,
      gif: true,
      gifFps: 15,
      gifMaxSide: 640,
      hdr: true,
    );

    final next = orig.copyWith(sources: [srcB], clips: const []);

    expect(next.sources.single.path, 'b.mov');
    // 這三組是以前漏掉的
    expect(next.hdr, isTrue, reason: 'hdr 掉了＝倒轉片段的 HDR 專案匯成 SDR');
    expect(next.gif, isTrue, reason: 'gif 掉了＝GIF 匯出來變影片');
    expect(next.fps, 60);
    expect(next.gifFps, 15);
    expect(next.gifMaxSide, 640);
    // 其餘照舊
    expect(next.timelineDuration, 12.5);
    expect(next.speed, 1.5);
    expect(identical(next.watermarkPng, wm), isTrue);
    expect(next.outW, 1080);
    expect(next.outH, 1920);
    expect(next.wmStart, 1);
    expect(next.wmEnd, 9);
    expect(next.wmAnimation, WmAnimation.marquee);
    expect(next.wmSpeed, 2);
    expect(next.wmRange, 0.7);
    expect(identical(next.overlayPngs, ov), isTrue);
    expect(next.crf, 20);
  });

  test('copyWith 不給參數＝原樣', () {
    final spec = ExportSpec(
      sources: const [],
      clips: const [],
      timelineDuration: 1,
      speed: 1,
      watermarkPng: null,
      outW: 100,
      outH: 100,
      hdr: true,
    );
    final same = spec.copyWith();
    expect(identical(same.sources, spec.sources), isTrue);
    expect(same.hdr, isTrue);
  });
}
