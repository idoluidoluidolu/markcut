import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/native_export.dart';
import 'package:markcut/services/video_processor.dart';

/// 原生匯出走的是「一條軌照順序播、整版 PNG 疊上去」的模型。
/// 做不到的一定要退回 FFmpeg——放行一個做不到的，成品就跟預覽不一樣，
/// 而使用者要等整支匯完才會發現。這幾條界線用測試釘死
void main() {
  MediaSource vid(String name, {double dur = 5}) => MediaSource(
    path: '/tmp/$name.mp4',
    name: name,
    kind: ClipKind.video,
    duration: dur,
    w: 1080,
    h: 1920,
  );

  MediaSource of(ClipKind kind) => MediaSource(
    path: '/tmp/x',
    name: 'x',
    kind: kind,
    duration: 5,
    w: 1080,
    h: 1920,
  );

  TimelineClip clip({
    int id = 1,
    int srcIndex = 0,
    double offset = 0,
    double len = 5,
    int track = 0,
    bool reverse = false,
  }) => TimelineClip(
    id: id,
    sourceIndex: srcIndex,
    trimStart: 0,
    trimEnd: len,
    offset: offset,
    track: track,
    reverse: reverse,
  );

  ExportSpec spec(List<MediaSource> sources, List<TimelineClip> clips) =>
      ExportSpec(
        sources: sources,
        clips: clips,
        timelineDuration: 10,
        speed: 1,
        watermarkPng: null,
        outW: 1080,
        outH: 1920,
      );

  group('原生匯出的資格', () {
    test('單純的影片時間軸：可以', () {
      final s = spec(
        [vid('a'), vid('b')],
        [
          clip(id: 1, srcIndex: 0),
          clip(id: 2, srcIndex: 1, offset: 5),
        ],
      );
      expect(NativeExport.whyNot(s), isNull);
    });

    test('片段之間有空白也可以（合成裡留黑）', () {
      final s = spec(
        [vid('a'), vid('b')],
        [
          clip(id: 1, srcIndex: 0),
          clip(id: 2, srcIndex: 1, offset: 8),
        ],
      );
      expect(NativeExport.whyNot(s), isNull);
    });

    test('文字與浮水印素材可以（整版 PNG 疊上去）', () {
      final s = spec(
        [vid('a'), of(ClipKind.text), of(ClipKind.wm)],
        [
          clip(id: 1, srcIndex: 0),
          clip(id: 2, srcIndex: 1, track: 1),
          clip(id: 3, srcIndex: 2, track: 2),
        ],
      );
      expect(NativeExport.whyNot(s), isNull);
    });

    test('配樂可以（另開一條聲音軌，允許跟畫面重疊）', () {
      final s = spec(
        [vid('a'), of(ClipKind.audio)],
        [
          clip(id: 1, srcIndex: 0),
          clip(id: 2, srcIndex: 1, track: 1),
        ],
      );
      expect(NativeExport.whyNot(s), isNull);
    });

    test('馬賽克要退回 FFmpeg（要逐格重算像素）', () {
      final s = spec(
        [vid('a'), of(ClipKind.mosaic)],
        [
          clip(id: 1, srcIndex: 0),
          clip(id: 2, srcIndex: 1, track: 1),
        ],
      );
      expect(NativeExport.whyNot(s), '有馬賽克');
    });

    test('照片素材要退回 FFmpeg（靜態畫面不能插進合成軌）', () {
      final s = spec(
        [vid('a'), of(ClipKind.image)],
        [
          clip(id: 1, srcIndex: 0),
          clip(id: 2, srcIndex: 1, offset: 5),
        ],
      );
      expect(NativeExport.whyNot(s), '有照片素材');
    });

    test('倒轉要退回 FFmpeg（播放器沒辦法倒著播）', () {
      final s = spec([vid('a')], [clip(id: 1, reverse: true)]);
      expect(NativeExport.whyNot(s), '有倒轉的片段');
    });

    test('子母畫面要退回 FFmpeg（同一時刻兩層畫面）', () {
      final s = spec(
        [vid('a'), vid('b')],
        [
          clip(id: 1, srcIndex: 0, len: 5),
          clip(id: 2, srcIndex: 1, offset: 2, track: 1),
        ],
      );
      expect(NativeExport.whyNot(s), '同一時刻有兩層畫面（子母畫面）');
    });

    test('只有文字沒有影片：退回 FFmpeg（合成軌是空的）', () {
      final s = spec([of(ClipKind.text)], [clip(id: 1)]);
      expect(NativeExport.whyNot(s), '沒有影片片段');
    });

    test('接得剛剛好（前一段的結束＝後一段的開始）不算重疊', () {
      final s = spec(
        [vid('a'), vid('b')],
        [
          clip(id: 1, srcIndex: 0, len: 5),
          clip(id: 2, srcIndex: 1, offset: 5, track: 1),
        ],
      );
      expect(NativeExport.whyNot(s), isNull);
    });
  });
}
