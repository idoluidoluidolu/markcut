// 「關於這個 App」加一顆斗內按鈕的版型比較（產圖工具，不是回歸測試）。
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/about_donate_shot_tool.dart
//
// 沒設環境變數時整支略過。用的是 App 真的色票、真的字體、關於頁真的
// 文案與頁尾，但畫面是這支自己組的（不動 lib/），純粹給人比較用。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/theme.dart';

final _shotKey = GlobalKey();

/// 關於頁上那段作者的話（跟 lib 裡同一份）
const _intro =
    '「浮水印」是一款完全免費的APP\n'
    '「浮水印」是一款完全不用錢的APP\n'
    '「浮水印」是一款FREE的APP\n'
    '「浮水印」是一款不收費的APP\n'
    '「浮水印」是一款售價0元的APP';

String? _materialIconsPath() {
  final candidates = <String>[];
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    candidates.add(
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  final exe = Platform.resolvedExecutable.replaceAll(
    String.fromCharCode(92),
    '/',
  );
  final i = exe.indexOf('/bin/cache/');
  if (i >= 0) {
    candidates.add(
      '${exe.substring(0, i)}'
      '/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

const _linkStyle = TextStyle(fontSize: 12.5, color: kLText);
const _dimStyle = TextStyle(fontSize: 11, color: kLTextDim);

Widget _dot() => const Padding(
  padding: EdgeInsets.symmetric(horizontal: 8),
  child: Text('·', style: TextStyle(fontSize: 12, color: kLTextDim)),
);

/// 關於頁真的頁尾（四個連結＋授權那一行）
Widget _footer({Widget? extra}) => Padding(
  padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
  child: Column(
    children: [
      ?extra,
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('開源授權', style: _linkStyle),
          _dot(),
          const Text('原始碼', style: _linkStyle),
          _dot(),
          const Text('隱私', style: _linkStyle),
          _dot(),
          const Text('播放偵測', style: _linkStyle),
        ],
      ),
      const SizedBox(height: 8),
      const Text('依 MPL 2.0 散布 · FFmpeg LGPL v2.1+', style: _dimStyle),
    ],
  ),
);

Widget _page({Widget? underIntro, Widget? footerExtra, Widget? overlay}) =>
    Scaffold(
      backgroundColor: kLBg,
      appBar: AppBar(backgroundColor: kLBg),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            _intro,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: kLTextDim,
                              height: 1.75,
                            ),
                          ),
                        ),
                        if (underIntro != null) ...[
                          const SizedBox(height: 34),
                          underIntro,
                        ],
                      ],
                    ),
                  ),
                ),
                _footer(extra: footerExtra),
              ],
            ),
            ?overlay,
          ],
        ),
      ),
    );

/// 黑色實心大鈕
Widget _solid({String label = '請我喝杯咖啡', IconData? icon}) => Center(
  child: DecoratedBox(
    decoration: const ShapeDecoration(color: kLAccent, shape: StadiumBorder()),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 26),
      child: SizedBox(
        height: 50,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: kLBg),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
                color: kLBg,
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

/// 描邊鈕
Widget _outlined({String label = '請我喝杯咖啡', IconData? icon}) => Center(
  child: DecoratedBox(
    decoration: const ShapeDecoration(
      shape: StadiumBorder(side: BorderSide(color: kLBorder, width: 1.5)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: SizedBox(
        height: 46,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 17, color: kLText),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: kLText,
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '產圖工具，要給輸出資料夾才會跑');
    return;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Directory(out).createSync(recursive: true);
    for (final path in const [
      'assets/fonts/NotoSansTC.ttf',
      'assets/fonts/NotoSansTC-Bold.ttf',
    ]) {
      final loader = FontLoader('NotoSansTC')
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
    final icons = _materialIconsPath();
    expect(icons, isNotNull, reason: '找不到 materialicons-regular.otf');
    final il = FontLoader('MaterialIcons')
      ..addFont(File(icons!).readAsBytes().then((b) => b.buffer.asByteData()));
    await il.load();
  });

  Future<void> shoot(WidgetTester t, String name, Widget home) async {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: LightPage(child: home),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump(const Duration(milliseconds: 40));
    }
    await t.runAsync(() async {
      final b =
          _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await b.toImage(pixelRatio: 3);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      im.dispose();
      File(
        '$out${Platform.pathSeparator}$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('A 文字下面一顆黑鈕', (t) async {
    await shoot(
      t,
      'd-a-solid',
      _page(underIntro: _solid(icon: Icons.favorite_border)),
    );
  });

  testWidgets('B 文字下面一顆描邊鈕', (t) async {
    await shoot(
      t,
      'd-b-outlined',
      _page(underIntro: _outlined(icon: Icons.local_cafe_outlined)),
    );
  });

  testWidgets('C 貼在頁尾連結上面', (t) async {
    await shoot(
      t,
      'd-c-footer',
      _page(
        footerExtra: Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _solid(icon: Icons.favorite_border),
        ),
      ),
    );
  });

  testWidgets('D 一張說明卡＋鈕', (t) async {
    await shoot(
      t,
      'd-d-card',
      _page(
        underIntro: DecoratedBox(
          decoration: const ShapeDecoration(
            color: kLTile,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.all(Radius.circular(20)),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
            child: Column(
              children: [
                const Text(
                  '覺得好用的話',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: kLText,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '一杯咖啡的贊助就夠讓它繼續長大',
                  style: TextStyle(fontSize: 12, color: kLTextDim),
                ),
                const SizedBox(height: 16),
                _solid(label: '斗內'),
              ],
            ),
          ),
        ),
      ),
    );
  });

  testWidgets('E 頁尾多一個文字連結', (t) async {
    await shoot(
      t,
      'd-e-link',
      _page(
        footerExtra: const Padding(
          padding: EdgeInsets.only(bottom: 14),
          child: Text(
            '請我喝杯咖啡',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: kLText,
              decoration: TextDecoration.underline,
              decorationThickness: 1.5,
            ),
          ),
        ),
      ),
    );
  });

  testWidgets('F 右上角一顆小圖示鈕', (t) async {
    await shoot(
      t,
      'd-f-appbar',
      _page(
        overlay: Positioned(
          right: 14,
          top: 0,
          child: DecoratedBox(
            decoration: const ShapeDecoration(
              color: kLTile,
              shape: StadiumBorder(),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.favorite_border, size: 16, color: kLText),
                  SizedBox(width: 6),
                  Text(
                    '斗內',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: kLText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  });
}
