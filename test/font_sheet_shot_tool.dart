// 字型總覽（產圖工具，不是回歸測試）：把 kFontOptions 裡每一種字型用
// Flutter 真的文字引擎畫一行，看子集化／烘字重之後的檔案在 App 裡長什麼樣。
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub --no-test-assets test/font_sheet_shot_tool.dart
//
// 沒設環境變數時整支略過。字型直接從 assets/fonts 的檔案載（不走資產包，
// 所以 --no-test-assets 也能跑），家族名跟 pubspec 登記的一樣
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/watermark_settings.dart';

final _shotKey = GlobalKey();

/// 家族名 → 檔名（跟 pubspec.yaml 的 fonts 段落對齊）
const _files = <String, List<String>>{
  'NotoSansTC': ['NotoSansTC.ttf'],
  'NotoSerifTC': ['NotoSerifTC.ttf'],
  'OpenHuninn': ['jf-openhuninn.ttf'],
  'LXGWWenKaiTC': ['LXGWWenKaiTC.ttf'],
  'ChocolateClassicalSans': ['ChocolateClassicalSans.ttf'],
  'Yozai': ['Yozai.ttf'],
  'FusionPixel': ['FusionPixel.ttf'],
  'Montserrat': ['Montserrat.ttf'],
  'PlayfairDisplay': ['PlayfairDisplay.ttf'],
  'Pacifico': ['Pacifico.ttf'],
  'BebasNeue': ['BebasNeue.ttf'],
  'Oswald': ['Oswald.ttf'],
  'Lobster': ['Lobster.ttf'],
  'Anton': ['Anton.ttf'],
  'CourierPrime': ['CourierPrime.ttf'],
  'Quicksand': ['Quicksand.ttf'],
  'SpaceGrotesk': ['SpaceGrotesk.ttf'],
  'AbrilFatface': ['AbrilFatface.ttf'],
  'DancingScript': ['DancingScript.ttf'],
  'Caveat': ['Caveat.ttf'],
  'PressStart2P': ['PressStart2P.ttf'],
};

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '產圖工具，要給輸出資料夾才會跑');
    return;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Directory(out).createSync(recursive: true);
    for (final e in _files.entries) {
      final loader = FontLoader(e.key);
      for (final f in e.value) {
        loader.addFont(
          File(
            'assets/fonts/$f',
          ).readAsBytes().then((b) => b.buffer.asByteData()),
        );
      }
      await loader.load();
    }
  });

  testWidgets('kFontOptions 每一種畫一行 → fonts.png', (t) async {
    // 每一種字型都要在 kFontOptions 裡，反過來也一樣：漏登記一邊就在這裡炸
    expect(
      kFontOptions.map((o) => o.family).toSet(),
      _files.keys.toSet(),
      reason: 'kFontOptions 與這裡的檔案表對不上',
    );

    // 一行＝14 的家族名＋44 的樣本，各留行距；外面 Padding 20 上下各一份
    const rowH = 100.0;
    final h = 40 + rowH * kFontOptions.length;
    t.view.devicePixelRatio = 2.0;
    t.view.physicalSize = Size(1000 * 2, h * 2);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          // 要有 Material 祖先，不然 Text 會套上「沒有樣式」的黃色雙底線
          home: Material(
            color: const Color(0xFF0C0F14),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final o in kFontOptions)
                    SizedBox(
                      height: rowH,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${o.label}  ·  ${o.family}',
                            style: const TextStyle(
                              fontFamily: 'NotoSansTC',
                              fontSize: 14,
                              color: Color(0xFF8B8B95),
                            ),
                          ),
                          Text(
                            '@我的浮水印 攝影日常 Photo 2026',
                            maxLines: 1,
                            style: TextStyle(
                              fontFamily: o.family,
                              fontSize: 44,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    await t.runAsync(() async {
      final b =
          _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await b.toImage(pixelRatio: 2);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      im.dispose();
      File(
        '$out${Platform.pathSeparator}fonts.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
