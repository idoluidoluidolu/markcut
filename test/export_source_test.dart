// 快速匯出的來源選擇：什麼時候可以拿工作檔當匯出來源。
//
// 換錯邊的後果是「畫質悄悄變差」（極致畫質卻吃了 1080p 工作檔）或
// 「白白慢」（明明可以吃工作檔卻去解 4K HDR），兩種都看不出來、
// 只能靠測試釘住。
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/video_processor.dart';

MediaSource _video({String? work}) => MediaSource(
  path: '/orig.mov',
  name: 'a',
  kind: ClipKind.video,
  duration: 10,
  w: 2160,
  h: 3840,
  workPath: work,
);

void main() {
  group('快速匯出的來源選擇', () {
    test('1080p＋標準畫質：有工作檔的影片換成工作檔', () {
      final (out, n) = fastExportSources(
        [_video(work: '/work.mp4'), _video()],
        outW: 1080,
        outH: 1920,
        quality: ExportQuality.standard,
      );
      expect(n, 1);
      expect(out[0].path, '/work.mp4');
      // 其他欄位照抄：比例與長度不能變
      expect(out[0].kind, ClipKind.video);
      expect(out[0].duration, 10);
      expect(out[0].w, 2160);
      // 沒有工作檔的維持原檔
      expect(out[1].path, '/orig.mov');
    });

    test('極致／無損畫質不換：畫質不妥協', () {
      for (final q in [ExportQuality.ultra, ExportQuality.lossless]) {
        final (out, n) = fastExportSources(
          [_video(work: '/work.mp4')],
          outW: 1080,
          outH: 1920,
          quality: q,
        );
        expect(n, 0, reason: '$q 不該換');
        expect(out.single.path, '/orig.mov');
      }
    });

    test('輸出超過 1080p 不換：工作檔只有 1080p', () {
      final (_, n) = fastExportSources(
        [_video(work: '/work.mp4')],
        outW: 2160,
        outH: 3840,
        quality: ExportQuality.standard,
      );
      expect(n, 0);
    });

    test('照片、聲音、浮水印素材一律不動', () {
      final photo = MediaSource(
        path: '/p.jpg',
        name: 'p',
        kind: ClipKind.image,
        duration: 3600,
        workPath: '/never.mp4',
      );
      final (out, n) = fastExportSources(
        [photo],
        outW: 1080,
        outH: 1080,
        quality: ExportQuality.standard,
      );
      expect(n, 0);
      expect(out.single.path, '/p.jpg');
    });

    test('低畫質也吃工作檔', () {
      final (_, n) = fastExportSources(
        [_video(work: '/work.mp4')],
        outW: 720,
        outH: 1280,
        quality: ExportQuality.low,
      );
      expect(n, 1);
    });
  });
}
