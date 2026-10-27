// 匯入匯出的尺寸數學：各種奇怪的素材尺寸都不能算出壞畫布。
//
// Pixel 螢幕錄影（1080x2410）教訓：奇怪的尺寸會一路傳到編碼器，
// 這裡把守第一關——算出來的畫布必須永遠是偶數、不放大、比例正確。
// （編碼器本身吃不吃得下是裝置的事，由工作檔的亮度驗證把關）
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/comp_player.dart';
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

  group('畫布的底（預覽框、匯出、合成同一段）', () {
    // 軌 0：橫式街景 0~6；軌 1：直式螢幕錄影 0.5~3.5（實機回報的排法）
    TimelineModel twoTracks({
      int baseW = 1920,
      int baseH = 1080,
      ClipKind baseKind = ClipKind.video,
    }) {
      final tl = TimelineModel();
      tl.sources
        ..add(
          MediaSource(
            path: 'base',
            name: 'base',
            kind: baseKind,
            duration: 6,
            w: baseW,
            h: baseH,
          ),
        )
        ..add(
          MediaSource(
            path: 'top.mp4',
            name: 'top',
            kind: ClipKind.video,
            duration: 3,
            w: 886,
            h: 1920,
          ),
        );
      tl.clips
        ..add(
          TimelineClip(
            id: 1,
            sourceIndex: 0,
            trimStart: 0,
            trimEnd: 6,
            offset: 0,
            track: 0,
          ),
        )
        ..add(
          TimelineClip(
            id: 2,
            sourceIndex: 1,
            trimStart: 0,
            trimEnd: 3,
            offset: 0.5,
            track: 1,
          ),
        );
      return tl;
    }

    test('「原始」認最底層、最早的那段，跟上層、播放頭都無關', () {
      final tl = twoTracks();
      expect(tl.canvasBase()?.id, 1);
      expect(canvasAspectOf(tl), closeTo(16 / 9, 1e-9));
      final (w, h) = computeCanvasSize(tl, ExportResolution.original);
      expect(w / h, closeTo(16 / 9, 0.01), reason: '匯出跟預覽框同一個形狀');
      // 同一軌更早的那段才是底
      tl.clips.first.offset = 1;
      tl.sources.add(
        MediaSource(
          path: 'early.mp4',
          name: 'early',
          kind: ClipKind.video,
          duration: 1,
          w: 1080,
          h: 1080,
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: 3,
          sourceIndex: 2,
          trimStart: 0,
          trimEnd: 1,
          offset: 0,
          track: 0,
        ),
      );
      expect(tl.canvasBase()?.id, 3);
      expect(canvasAspectOf(tl), closeTo(1, 1e-9));
    });

    test('固定比例、自訂比例蓋過底；壞值退 16:9；沒有畫面素材 16:9', () {
      final tl = twoTracks();
      expect(canvasAspectOf(tl, CanvasRatio.r9_16), closeTo(9 / 16, 1e-9));
      expect(canvasAspectOf(tl, CanvasRatio.original, 2.0), 2.0);
      expect(canvasAspectOf(tl, CanvasRatio.original, double.nan), 16 / 9);
      expect(canvasAspectOf(TimelineModel()), 16 / 9);
      expect(canvasAspectOf(TimelineModel(), CanvasRatio.r1_1), 1.0);
    });

    test('合成：底層就是影片不送比例（交給原生量播的那支檔）', () {
      expect(CompPlayer.canvasAspectFor(twoTracks()), isNull);
      expect(
        CompPlayer.canvasAspectFor(twoTracks(), fixed: 9 / 16),
        9 / 16,
        reason: '固定比例照送',
      );
      // 差不到 1%（工作檔轉正縮過的捨入）也交給原生，不硬送多一條黑線
      final tl = twoTracks();
      tl.sources.add(
        MediaSource(
          path: 'same.mp4',
          name: 'same',
          kind: ClipKind.video,
          duration: 6,
          w: 1280,
          h: 722,
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: 3,
          sourceIndex: 2,
          trimStart: 0,
          trimEnd: 6,
          offset: 0,
          track: 2,
        ),
      );
      expect(CompPlayer.canvasAspectFor(tl, hiddenTracks: {0, 1}), isNull);
    });

    test('合成：底層是圖片、或最底軌隱藏，送畫布的比例', () {
      final img = twoTracks(
        baseW: 1080,
        baseH: 1920,
        baseKind: ClipKind.image,
      );
      expect(
        CompPlayer.canvasAspectFor(img),
        closeTo(1080 / 1920, 1e-9),
        reason: '原生只挑影片當底：會照上層直式螢幕錄影組',
      );
      expect(
        CompPlayer.canvasAspectFor(twoTracks(), hiddenTracks: {0}),
        closeTo(16 / 9, 1e-9),
        reason: '最底軌隱藏：原生會照上層直式組，匯出照舊是橫的',
      );
    });
  });

  test('順暢度：超過 60 的來源在 4K 以上會被壓到 60', () {
    expect(outputFps(120, 3840, 2160), 60);
    expect(outputFps(120, 1920, 1080), 120);
    // 指定值不能超過來源
    expect(outputFps(24, 1920, 1080, want: 60), 24);
    expect(outputFps(60, 1920, 1080, want: 30), 30);
  });
}
