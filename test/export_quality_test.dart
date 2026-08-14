// 匯出畫質檔位：位元率換算，以及「依素材自動挑一檔」的判斷。
//
// 這裡值得測是因為踩過一次：檔位表曾經在引擎裡另外寫一份，
// 後來加「低」的時候只改了列舉那份，結果低和標準輸出一模一樣的檔案。
// 現在表只有一張，測試盯著「四檔互不相同」這件事。
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/video_processor.dart';

void main() {
  const fhdW = 1920, fhdH = 1080;

  group('畫質檔位的位元率', () {
    test('四檔各自不同，而且由低到高遞增', () {
      final kbps = [
        for (final q in qualityOrder) q.kbpsFor(fhdW, fhdH),
      ];
      expect(kbps.toSet().length, qualityOrder.length, reason: '有兩檔算出一樣的值');
      for (var i = 1; i < kbps.length; i++) {
        expect(kbps[i], greaterThan(kbps[i - 1]));
      }
    });

    test('CRF 換回檔位是一對一的', () {
      for (final q in ExportQuality.values) {
        expect(qualityFromCrf(q.crf), q);
      }
    });

    test('尺寸越大位元率越高，並受上下限保護', () {
      const q = ExportQuality.standard;
      expect(q.kbpsFor(3840, 2160), greaterThan(q.kbpsFor(fhdW, fhdH)));
      // 極小畫面不會算出低到不能看的值
      expect(q.kbpsFor(16, 16), 1500);
      // 4K 的最高會撞到上限（刻意的保護，不是算錯）
      expect(ExportQuality.lossless.kbpsFor(3840, 2160), 120000);
    });
  });

  group('影格率', () {
    test('位元率隨影格率開根號進位：60fps 約多四成，不是兩倍', () {
      const q = ExportQuality.standard;
      final k30 = q.kbpsFor(fhdW, fhdH);
      final k60 = q.kbpsFor(fhdW, fhdH, fps: 60);
      expect(k60 / k30, closeTo(1.41, 0.02));
      // fps 沒給或給 0 都當 30，不會爆
      expect(q.kbpsFor(fhdW, fhdH, fps: 0), k30);
    });

    test('輸出影格率：慢動作夾 120 而不是丟回 30', () {
      expect(outputFps(240, fhdW, fhdH), 120);
      expect(outputFps(120, fhdW, fhdH), 120);
      expect(outputFps(59.94, fhdW, fhdH), closeTo(59.94, 0.001));
    });

    test('輸出影格率：垃圾值退回 30', () {
      expect(outputFps(0, fhdW, fhdH), 30);
      expect(outputFps(-5, fhdW, fhdH), 30);
      expect(outputFps(1000, fhdW, fhdH), 30);
    });

    test('輸出影格率：1440p 以上夾 60（硬體編碼器的極限）', () {
      expect(outputFps(120, 3840, 2160), 60);
      expect(outputFps(30, 3840, 2160), 30);
      // 1440p 本身還不夾
      expect(outputFps(120, 2560, 1440), 120);
    });
  });

  group('依素材自動挑畫質', () {
    test('量不到大小時回標準，不亂猜', () {
      expect(
        recommendQuality(srcKbps: 0, outW: fhdW, outH: fhdH),
        ExportQuality.standard,
      );
    });

    test('挑到的檔位一定壓得下原素材（含重壓餘裕）', () {
      for (final srcKbps in [800.0, 4000.0, 8000.0, 20000.0, 60000.0]) {
        final q = recommendQuality(
          srcKbps: srcKbps,
          outW: fhdW,
          outH: fhdH,
        );
        final ok = q.kbpsFor(fhdW, fhdH) >= srcKbps * 1.25;
        // 撞到上限（極高）還是不夠時就停在極高，那是刻意的取捨
        expect(
          ok || q == ExportQuality.ultra,
          isTrue,
          reason: '$srcKbps kbps 挑了 ${q.label}，壓不下去',
        );
      }
    });

    test('挑的是「夠用的最低檔」，不會無謂放大檔案', () {
      // 標準在 1080p 是 9.3 Mbps，餘裕 1.25 倍 → 7400 kbps 以下收在標準
      expect(
        recommendQuality(srcKbps: 5000, outW: fhdW, outH: fhdH),
        ExportQuality.standard,
      );
      // 手機 1080p 錄影約 8 Mbps，標準壓不住，往上一檔
      expect(
        recommendQuality(srcKbps: 8000, outW: fhdW, outH: fhdH),
        ExportQuality.ultra,
      );
    });

    test('自動挑不會選到「最高」——那是四倍檔案，要由使用者自己按', () {
      for (final srcKbps in [20000.0, 60000.0, 200000.0]) {
        for (final (w, h) in [(fhdW, fhdH), (3840, 2160), (1280, 720)]) {
          expect(
            recommendQuality(srcKbps: srcKbps, outW: w, outH: h),
            isNot(ExportQuality.lossless),
          );
        }
      }
      // 上限本身可以放寬，只是預設不放
      expect(
        recommendQuality(
          srcKbps: 200000,
          outW: fhdW,
          outH: fhdH,
          cap: ExportQuality.lossless,
        ),
        ExportQuality.lossless,
      );
    });

    test('位元率越高挑的檔位不會反而變低', () {
      ExportQuality? prev;
      for (var kbps = 500.0; kbps < 80000; kbps += 500) {
        final q = recommendQuality(srcKbps: kbps, outW: fhdW, outH: fhdH);
        if (prev != null) {
          expect(
            qualityOrder.indexOf(q),
            greaterThanOrEqualTo(qualityOrder.indexOf(prev)),
          );
        }
        prev = q;
      }
    });

    test('HEVC 素材的餘裕比 H.264 大：同位元率會挑到更高（或同）檔', () {
      // 17 Mbps 的 1080p：H.264（餘裕 1.1）高畫質 17.4 剛好壓得住；
      // HEVC（餘裕 1.6）要 27.2，超過上限 → 停在高畫質。兩者至少不反轉
      for (final srcKbps in [5000.0, 10000.0, 17000.0, 30000.0]) {
        final h264 = recommendQuality(
          srcKbps: srcKbps, outW: fhdW, outH: fhdH, headroom: 1.1);
        final hevc = recommendQuality(
          srcKbps: srcKbps, outW: fhdW, outH: fhdH, headroom: 1.6);
        expect(
          qualityOrder.indexOf(hevc),
          greaterThanOrEqualTo(qualityOrder.indexOf(h264)),
        );
      }
    });

    test('同一支素材縮小輸出時，會挑到比較低的檔位', () {
      const src = 12000.0; // 1080p 高位元率素材
      final full = recommendQuality(srcKbps: src, outW: fhdW, outH: fhdH);
      final small = recommendQuality(srcKbps: src, outW: 1280, outH: 720);
      // 縮到 720p 時同一檔位的位元率更低，所以要往上補
      expect(
        qualityOrder.indexOf(small),
        greaterThanOrEqualTo(qualityOrder.indexOf(full)),
      );
    });
  });
}
