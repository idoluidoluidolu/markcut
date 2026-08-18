// 多文字浮水印（跟多圖同一套模式）：清單＋操作中索引。
//
// 重點釘兩件事：舊資料（單一 text 鍵）讀進來不能掉，
// 以及所有透過 `s.text` 的舊呼叫點操作的永遠是「操作中的那一個」。
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';

void main() {
  group('多文字', () {
    test('預設一個；addText 錯開位置並切成操作中', () {
      final s = WatermarkSettings();
      expect(s.texts.length, 1);
      s.text.text = '第一個';
      final added = s.addText();
      expect(s.texts.length, 2);
      expect(s.activeText, 1);
      expect(identical(s.text, added), isTrue);
      // 位置錯開，不會整個疊在舊的上面
      expect(added.x != s.texts[0].x || added.y != s.texts[0].y, isTrue);
      // 透過 getter 改的是新的那個
      s.text.text = '第二個';
      expect(s.texts[0].text, '第一個');
      expect(s.texts[1].text, '第二個');
    });

    test('removeText：最後一個只清空不移除', () {
      final s = WatermarkSettings();
      s.addText();
      s.removeText(1);
      expect(s.texts.length, 1);
      s.text.text = '嗨';
      s.removeText(0);
      expect(s.texts.length, 1);
      expect(s.text.text, isNot('嗨')); // 清空成預設
    });

    test('JSON 來回：多個文字與操作中索引都保留', () {
      final s = WatermarkSettings();
      s.text.text = 'A';
      s.addText().text = 'B';
      s.activeText = 0;
      final back = WatermarkSettings.fromJson(s.toJson());
      expect(back.texts.length, 2);
      expect(back.texts[0].text, 'A');
      expect(back.texts[1].text, 'B');
      expect(back.activeText, 0);
    });

    test('舊資料只有單一 text 鍵：讀成一個的清單', () {
      final back = WatermarkSettings.fromJson({
        'text': {'text': '老草稿', 'enabled': true},
      });
      expect(back.texts.length, 1);
      expect(back.text.text, '老草稿');
    });

    test('copyMarksFrom 帶著整份清單走（套範本／復原）', () {
      final a = WatermarkSettings();
      a.text.text = 'X';
      a.addText().text = 'Y';
      final b = WatermarkSettings();
      b.copyMarksFrom(a.copy());
      expect(b.texts.length, 2);
      expect(b.texts.map((t) => t.text), containsAll(['X', 'Y']));
    });

    test('hasAnyMark：任何一個開著的文字都算', () {
      final s = WatermarkSettings();
      s.text.text = '';
      s.addText().text = '有字';
      s.texts[0].enabled = false;
      expect(s.hasAnyMark, isTrue);
      s.texts[1].text = '';
      expect(s.hasAnyMark, isFalse);
    });
  });
}
