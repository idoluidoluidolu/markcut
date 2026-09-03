import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';

/// 面板的滑桿讀數（watermark_panel 的 _sliderRow：值×100，單位 %）
int readout(double v) => (v * 100).round();

void main() {
  group('新建的浮水印文字：陰影濃度 75、粗細 50', () {
    test('建構子預設', () {
      final t = TextMark();
      expect(readout(t.shadowOpacity), 75);
      expect(readout(t.weight), 50);
    });

    test('新的一組設定、以及「再加一個文字」都吃新預設', () {
      final s = WatermarkSettings();
      expect(readout(s.text.shadowOpacity), 75);
      expect(readout(s.text.weight), 50);

      final added = s.addText();
      expect(readout(added.shadowOpacity), 75);
      expect(readout(added.weight), 50);
    });

    test('刪到只剩一個時重建的那一個也吃新預設', () {
      final s = WatermarkSettings()..text.shadowOpacity = 0.1;
      s.removeText(0);
      expect(readout(s.text.shadowOpacity), 75);
      expect(readout(s.text.weight), 50);
    });

    test('值在滑桿範圍內（濃度 0.05~1、粗細 0~1）', () {
      final t = TextMark();
      expect(t.shadowOpacity, inInclusiveRange(0.05, 1.0));
      expect(t.weight, inInclusiveRange(0.0, 1.0));
    });
  });

  group('舊資料不被改預設波及', () {
    test('沒存過這兩個欄位的舊紀錄，退回舊值（55／20）而不是新預設', () {
      // 這兩個欄位還沒存在的年代留下來的範本／草稿
      final old = TextMark.fromJson({'text': '@我的浮水印', 'sizeFrac': 0.05});
      expect(readout(old.shadowOpacity), 55);
      expect(readout(old.weight), 20);
    });

    test('有明確存值的舊紀錄，原封不動讀回來', () {
      final old = TextMark.fromJson({
        'text': '@我的浮水印',
        'shadowOpacity': 0.32,
        'weight': 0.08,
      });
      expect(old.shadowOpacity, closeTo(0.32, 1e-9));
      expect(old.weight, closeTo(0.08, 1e-9));
    });

    test('舊範本存檔 → 解碼，濃度與粗細跟存下去時一樣', () {
      // 舊版本存下來的一筆（那時的預設就是 55／20）
      final saved = WatermarkPreset(
        name: '頻道標準',
        settings: WatermarkSettings(
          text: TextMark(text: '@我的頻道', shadowOpacity: 0.55, weight: 0.2),
        ),
      ).encode();

      final back = WatermarkPreset.decode(saved);
      expect(readout(back.settings.text.shadowOpacity), 55);
      expect(readout(back.settings.text.weight), 20);
    });

    test('copy()／草稿往返不會把值換成新預設', () {
      final t = TextMark(shadowOpacity: 0.4, weight: 0.15);
      final c = t.copy();
      expect(c.shadowOpacity, closeTo(0.4, 1e-9));
      expect(c.weight, closeTo(0.15, 1e-9));

      final s = WatermarkSettings(text: t).copy();
      expect(s.text.shadowOpacity, closeTo(0.4, 1e-9));
      expect(s.text.weight, closeTo(0.15, 1e-9));
    });
  });
}
