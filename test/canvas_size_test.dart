// 匯入匯出的尺寸數學：各種奇怪的素材尺寸都不能算出壞畫布。
//
// Pixel 螢幕錄影（1080x2410）教訓：奇怪的尺寸會一路傳到編碼器，
// 這裡把守第一關——算出來的畫布必須永遠是偶數、不放大、比例正確。
// （編碼器本身吃不吃得下是裝置的事，由工作檔的亮度驗證把關）
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/video_processor.dart';

TimelineModel _tl(int w, int h) {
  final tl = TimelineModel();
  tl.sources.add(
    MediaSource(
      path: 'x.mp4',
      name: 'x',
      kind: ClipKind.video,
      duration: 10,
      w: w,
      h: h,
    ),
  );
  tl.clips.add(
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 10,
      offset: 0,
      track: 0,
    ),
  );
  return tl;
}

void main() {
  // 各種會出現在真實世界的尺寸：
  // 相機直橫式、螢幕錄影（非 16 倍數）、奇數、超小、超大、極端長條
  const sizes = [
    (1920, 1080),
    (1080, 1920),
    (1080, 2410), // Pixel 螢幕錄影：非 16 倍數
    (2410, 1080),
    (1079, 1919), // 奇數
    (720, 1560),
    (886, 1920),
    (3840, 2160),
    (2160, 3840),
    (7680, 4320), // 8K
    (640, 480),
    (100, 3000), // 極端長條
    (0, 0), // 尺寸還沒讀到
    (1, 1),
  ];

  test('各種素材尺寸 × 解析度：畫布永遠偶數、不小於 2、不放大', () {
    for (final (w, h) in sizes) {
      for (final res in ExportResolution.values) {
        final (cw, ch) = computeCanvasSize(_tl(w, h), res);
        expect(cw % 2, 0, reason: '$w x $h @$res 寬要偶數，算出 $cw');
        expect(ch % 2, 0, reason: '$w x $h @$res 高要偶數，算出 $ch');
        expect(cw, greaterThanOrEqualTo(2), reason: '$w x $h @$res');
        expect(ch, greaterThanOrEqualTo(2), reason: '$w x $h @$res');
        // 只縮不放：長邊不能超過素材長邊（素材尺寸沒讀到時退 1920）
        final srcLong = (w > h ? w : h) < 16 ? 1920 : (w > h ? w : h);
        final capLong = switch (res) {
          ExportResolution.original => srcLong,
          ExportResolution.fhd1080 => 1920,
          ExportResolution.hd720 => 1280,
        };
        final outLong = cw > ch ? cw : ch;
        expect(
          outLong,
          lessThanOrEqualTo(capLong < srcLong ? capLong : srcLong),
          reason: '$w x $h @$res 長邊 $outLong 超過上限',
        );
      }
    }
  });

  test('比例選項：算出來的畫布比例要貼合要求（誤差 < 2%）', () {
    for (final (w, h) in sizes) {
      if (w < 16 || h < 16) continue; // 尺寸沒讀到的另外測
      for (final ratio in CanvasRatio.values) {
        final want = ratio.value ?? w / h;
        final (cw, ch) = computeCanvasSize(
          _tl(w, h),
          ExportResolution.original,
          ratio,
        );
        final got = cw / ch;
        expect(
          (got - want).abs() / want,
          lessThan(0.02),
          reason: '$w x $h $ratio 要 $want 算出 $got（$cw x $ch）',
        );
      }
    }
  });

  test('自訂比例：極端值與壞值都不炸、不出壞尺寸', () {
    for (final aspect in [0.1, 0.5, 1.0, 2.0, 10.0, double.nan, -1.0, 0.0]) {
      final (cw, ch) = computeCanvasSize(
        _tl(1920, 1080),
        ExportResolution.original,
        CanvasRatio.original,
        aspect,
      );
      expect(cw % 2, 0, reason: 'aspect=$aspect');
      expect(ch % 2, 0, reason: 'aspect=$aspect');
      expect(cw, greaterThanOrEqualTo(2), reason: 'aspect=$aspect');
      expect(ch, greaterThanOrEqualTo(2), reason: 'aspect=$aspect');
    }
  });

  test('順暢度：超過 60 的來源在 4K 以上會被壓到 60', () {
    expect(outputFps(120, 3840, 2160), 60);
    expect(outputFps(120, 1920, 1080), 120);
    // 指定值不能超過來源
    expect(outputFps(24, 1920, 1080, want: 60), 24);
    expect(outputFps(60, 1920, 1080, want: 30), 30);
  });
}
