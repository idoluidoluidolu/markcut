// 讀進來的字型家族名一定要是清單裡有的那幾個。
//
// 為什麼要守：範本與草稿存的是家族名字串，而字型清單會增減——朱古力
// 黑體就是被拿掉的那一個。字型下拉是 DropdownButton，value 不在 items
// 裡時 Flutter 會直接斷言炸掉（「There should be exactly one item with
// [DropdownButton]'s value」），所以認不得的字型要在讀進來的當下就換掉，
// 不能等畫面去踩。
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';

void main() {
  test('認得的字型原樣留著', () {
    for (final o in kFontOptions) {
      expect(sanitizeFontFamily(o.family), o.family);
    }
  });

  test('認不得的、空的、null 都退回清單第一個（思源黑體）', () {
    for (final bad in <String?>[
      'ChocolateClassicalSans', // 拿掉的那一個
      'SomeFontWeNeverShipped',
      '',
      null,
    ]) {
      expect(
        sanitizeFontFamily(bad),
        kFontOptions.first.family,
        reason: '「$bad」沒有被換掉',
      );
    }
    expect(kFontOptions.first.family, 'NotoSansTC');
  });

  test('舊範本存著拿掉的字型：讀回來是思源黑體，其餘欄位不動', () {
    final old = {
      'enabled': true,
      'text': '@我的浮水印',
      'fontFamily': 'ChocolateClassicalSans',
      'sizeFrac': 0.08,
      'x': 0.3,
      'y': 0.7,
    };
    final t = TextMark.fromJson(old);
    expect(t.fontFamily, 'NotoSansTC');
    expect(t.text, '@我的浮水印');
    expect(t.sizeFrac, closeTo(0.08, 1e-9));
    expect(t.x, closeTo(0.3, 1e-9));
    expect(t.y, closeTo(0.7, 1e-9));
  });

  test('整組設定（含多個文字）都會被淨化', () {
    final s = WatermarkSettings.fromJson({
      'texts': [
        {'fontFamily': 'ChocolateClassicalSans', 'text': 'A'},
        {'fontFamily': 'Yozai', 'text': 'B'},
      ],
    });
    expect(s.texts.map((t) => t.fontFamily), ['NotoSansTC', 'Yozai']);
    expect(s.texts.map((t) => t.text), ['A', 'B']);
  });

  test('存回去的家族名一定在清單裡（存檔不會把壞值寫回去）', () {
    final t = TextMark.fromJson({'fontFamily': 'ChocolateClassicalSans'});
    final round = TextMark.fromJson(t.toJson());
    expect(
      kFontOptions.any((o) => o.family == round.fontFamily),
      isTrue,
      reason: '存讀一輪之後還是認不得的字型',
    );
  });
}
