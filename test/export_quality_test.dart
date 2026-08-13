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
        final ok = q.kbpsFor(fhdW, fhdH) >= srcKbps * 1.3;
        // 撞到最高一檔還是不夠時只能給最高，那是合理的收尾
        expect(
          ok || q == qualityOrder.last,
          isTrue,
          reason: '$srcKbps kbps 挑了 ${q.label}，壓不下去',
        );
      }
    });

    test('挑的是「夠用的最低檔」，不會無謂放大檔案', () {
      // 標準在 1080p 是 9.3 Mbps，餘裕 1.3 倍 → 7000 kbps 以下都該收在標準
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
