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

  // HDR 輸出：以前這條路只認 SDR 工作檔，而 HDR 模式根本不做那份——
  // 4K HDR 專案選標準畫質照樣整支 4K 過 4K 半浮點合成器（全 App 最慢）；
  // 更糟的是明確選 1080p 時會把 HDR 素材換成 SDR 工作檔，Swift 端讀不到
  // HLG 標記，整支 HDR 匯出靜默變 SDR。這幾條釘死
  group('快速匯出的來源選擇（HDR 輸出）', () {
    MediaSource src({String? work, String? hdr, String path = '/orig.mov'}) =>
        MediaSource(
          path: path,
          name: 'a',
          kind: ClipKind.video,
          duration: 10,
          w: 2160,
          h: 3840,
          workPath: work,
          workHdrPath: hdr,
        );

    test('HDR 素材換成 HLG 代理，不是 SDR 工作檔', () {
      final (out, n) = fastExportSources(
        [src(work: '/work.mp4', hdr: '/hlg.mp4')],
        outW: 1080,
        outH: 1920,
        quality: ExportQuality.standard,
        hdr: true,
        isHdr: (_) => true,
      );
      expect(n, 1);
      expect(out.single.path, '/hlg.mp4');
    });

    test('HDR 素材只有 SDR 工作檔、沒有 HLG 代理：維持原檔（不能丟掉 HDR）', () {
      final (out, n) = fastExportSources(
        [src(work: '/work.mp4')],
        outW: 1080,
        outH: 1920,
        quality: ExportQuality.standard,
        hdr: true,
        isHdr: (_) => true,
      );
      expect(n, 0);
      expect(out.single.path, '/orig.mov');
    });

    test('HDR 模式下的 SDR 素材照用 SDR 工作檔（跟原檔一樣是 709）', () {
      final (out, n) = fastExportSources(
        [src(work: '/work.mp4')],
        outW: 1080,
        outH: 1920,
        quality: ExportQuality.standard,
        hdr: true,
        isHdr: (_) => false,
      );
      expect(n, 1);
      expect(out.single.path, '/work.mp4');
    });

    test('沒人講是不是 HDR：有 HLG 代理就用它，只有工作檔的不冒險', () {
      final (out, n) = fastExportSources(
        [
          src(work: '/w1.mp4', hdr: '/h1.mp4', path: '/a.mov'),
          src(work: '/w2.mp4', path: '/b.mov'),
        ],
        outW: 1080,
        outH: 1920,
        quality: ExportQuality.standard,
        hdr: true,
      );
      expect(n, 1);
      expect(out[0].path, '/h1.mp4');
      expect(out[1].path, '/b.mov');
    });

    test('SDR 輸出不看 HLG 代理（HLG 像素進 SDR 管線要再映射一次）', () {
      final (out, n) = fastExportSources(
        [src(hdr: '/hlg.mp4')],
        outW: 1080,
        outH: 1920,
        quality: ExportQuality.standard,
        hdr: false,
        isHdr: (_) => true,
      );
      expect(n, 0);
      expect(out.single.path, '/orig.mov');
    });

    test('HDR 模式的門票（exportProxyPath）跟來源替換是同一條規則', () {
      final a = src(work: '/w.mp4', hdr: '/h.mp4');
      expect(exportProxyPath(a, hdr: true, isHdr: true), '/h.mp4');
      expect(exportProxyPath(a, hdr: true, isHdr: false), '/w.mp4');
      expect(exportProxyPath(a, hdr: true), '/h.mp4');
      expect(exportProxyPath(a, hdr: false, isHdr: true), '/w.mp4');
      final b = src(work: '/w.mp4');
      expect(exportProxyPath(b, hdr: true, isHdr: true), isNull);
      expect(exportProxyPath(b, hdr: true), isNull);
      expect(exportProxyPath(b, hdr: true, isHdr: false), '/w.mp4');
      // 非影片素材永遠沒有門票
      final photo = MediaSource(
        path: '/p.jpg',
        name: 'p',
        kind: ClipKind.image,
        duration: 3,
        workPath: '/never.mp4',
        workHdrPath: '/never2.mp4',
      );
      expect(exportProxyPath(photo, hdr: true, isHdr: true), isNull);
      expect(exportProxyPath(photo, hdr: false), isNull);
    });
  });
}
