// 粉圓的漢字源自 Kosugi Maru（Apache License 2.0）：授權清單要有原版權
// 聲明跟條款全文。
//
// 為什麼要守：全文是資產檔（assets/licenses/Apache-2.0.txt），授權頁打開
// 時才讀。資產沒在 pubspec 登記，讀檔會丟例外，整個授權清單都出不來；
// Windows 上 checkout 的檔是 CRLF，沒換掉的話授權頁每一段都夾著 \r。
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Kosugi Maru 那一則：版權聲明＋Apache License 2.0 全文，沒有 \\r', () async {
    final entry = await kosugiMaruLicense();
    expect(entry.packages, ['字型']);
    final paragraphs = entry.paragraphs.map((p) => p.text).toList();
    final text = paragraphs.join('\n');
    expect(text, contains('Copyright (c) 2010 MOTOYA CO.,LTD.'));
    expect(text, contains('Version 2.0, January 2004'));
    expect(text, contains('4. Redistribution.'));
    expect(text, contains('END OF TERMS AND CONDITIONS'));
    expect(text, isNot(contains('\r')));
    // 整份都在：全文切得出四十幾段，只讀到一部分或讀錯檔就不夠
    expect(paragraphs.length, greaterThan(40));
  });
}
