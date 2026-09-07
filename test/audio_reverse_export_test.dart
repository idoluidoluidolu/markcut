// 原生匯出的門（NativeExport.whyNot）對「倒轉」的判定只看影片。
//
// 聲音片段的倒轉以前只有簡易模式（掛旗標、匯出時主濾鏡 areverse），而
// whyNot 不分種類一看到 reverse 就整份退 FFmpeg——一段配樂拉成倒轉，HDR
// 專案就靜默匯成 SDR、4K 軟解色調映射吃記憶體。現在聲音跟影片一樣在
// exportVideoToGallery 進門前被預渲染成「已倒好」的檔（areverse），
// whyNot 只擋「前置處理漏掉」的影片倒轉
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/native_export.dart';
import 'package:markcut/services/video_processor.dart';

void main() {
  MediaSource src(ClipKind kind, String name) => MediaSource(
    path: '/tmp/$name',
    name: name,
    kind: kind,
    duration: 10,
    w: kind == ClipKind.video ? 1080 : 0,
    h: kind == ClipKind.video ? 1920 : 0,
  );

  TimelineClip clip({
    required int id,
    required int srcIndex,
    int track = 0,
    bool reverse = false,
  }) => TimelineClip(
    id: id,
    sourceIndex: srcIndex,
    trimStart: 0,
    trimEnd: 5,
    offset: 0,
    track: track,
    reverse: reverse,
  );

  ExportSpec spec(List<MediaSource> sources, List<TimelineClip> clips) =>
      ExportSpec(
        sources: sources,
        clips: clips,
        timelineDuration: 5,
        speed: 1,
        watermarkPng: null,
        outW: 1080,
        outH: 1920,
        hdr: true,
      );

  test('聲音片段還掛著 reverse：原生匯出照樣可以（聲音在前置就倒好了）', () {
    final s = spec(
      [src(ClipKind.video, 'a.mov'), src(ClipKind.audio, 'm.m4a')],
      [
        clip(id: 1, srcIndex: 0),
        clip(id: 2, srcIndex: 1, track: 1, reverse: true),
      ],
    );
    expect(
      NativeExport.whyNot(s),
      isNull,
      reason: '一段倒轉的配樂不該把整份 HDR 匯出踢回 FFmpeg',
    );
  });

  test('影片片段的 reverse 還是要擋（前置處理漏掉的保險）', () {
    final s = spec(
      [src(ClipKind.video, 'a.mov'), src(ClipKind.audio, 'm.m4a')],
      [
        clip(id: 1, srcIndex: 0, reverse: true),
        clip(id: 2, srcIndex: 1, track: 1),
      ],
    );
    expect(NativeExport.whyNot(s), contains('倒轉'));
  });

  test('倒好的聲音檔換上之後（reverse 關掉）走原生：audios 一樣進 payload 的資格', () {
    // 前置處理做完的形狀：聲音片段改指到倒好的檔、旗標關掉
    final s = spec(
      [src(ClipKind.video, 'a.mov'), src(ClipKind.audio, 'reva.m4a')],
      [
        clip(id: 1, srcIndex: 0),
        clip(id: 2, srcIndex: 1, track: 1),
      ],
    );
    expect(NativeExport.whyNot(s), isNull);
    expect(NativeExport.needsLayered(s), isFalse, reason: '聲音不開圖層模式');
  });
}
