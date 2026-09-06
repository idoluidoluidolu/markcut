// 首頁那顆＋的樣式與位置比較（產圖工具，不是回歸測試）。
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/home_fab_shot_tool.dart
//
// 沒設環境變數時整支略過。用 App 真的色票、真的 logo、真的字體，
// 但畫面是這支自己組的（不動 lib/），純粹給人比較用。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/theme.dart';

final _shotKey = GlobalKey();

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

/// 一張首頁：logo 置中，底下放 [button]（位置由 [align] 與 [pad] 決定）
Widget _home({
  required Widget button,
  Alignment align = Alignment.bottomRight,
  EdgeInsets pad = const EdgeInsets.only(right: 22, bottom: 30),
  String? note,
}) => Scaffold(
  backgroundColor: kLBg,
  appBar: AppBar(
    backgroundColor: kLBg,
    actions: const [
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: Icon(Icons.person_outline, size: 28),
      ),
    ],
  ),
  body: Stack(
    children: [
      Center(
        child: SizedBox(
          width: 190,
          height: 76,
          child: Image.asset(
            'assets/icon/home_logo.png',
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
      if (note != null)
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              note,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: kLTextDim,
              ),
            ),
          ),
        ),
      Align(
        alignment: align,
        child: Padding(padding: pad, child: button),
      ),
    ],
  ),
);

/// 圓形實心＋
Widget _circle({double size = 62, double icon = 30}) => DecoratedBox(
  decoration: const ShapeDecoration(color: kLAccent, shape: CircleBorder()),
  child: SizedBox(
    width: size,
    height: size,
    child: Center(
      child: Icon(Icons.add, size: icon, color: kLBg),
    ),
  ),
);

/// 圓角方形＋（超橢圓）
Widget _squircle({double size = 62, double icon = 30, double radius = 20}) =>
    DecoratedBox(
      decoration: ShapeDecoration(
        color: kLAccent,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.all(Radius.circular(radius)),
        ),
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Icon(Icons.add, size: icon, color: kLBg),
        ),
      ),
    );

/// 描邊圓形＋（白底黑邊）
Widget _outlined({double size = 62, double icon = 30}) => DecoratedBox(
  decoration: const ShapeDecoration(
    color: kLBg,
    shape: CircleBorder(side: BorderSide(color: kLAccent, width: 2)),
  ),
  child: SizedBox(
    width: size,
    height: size,
    child: Center(
      child: Icon(Icons.add, size: icon, color: kLAccent),
    ),
  ),
);

/// 帶字的膠囊（＋ 開始）
Widget _pill({String label = '開始'}) => DecoratedBox(
  decoration: const ShapeDecoration(color: kLAccent, shape: StadiumBorder()),
  child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: SizedBox(
      height: 56,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.add, size: 22, color: kLBg),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
              color: kLBg,
            ),
          ),
        ],
      ),
    ),
  ),
);

/// 滿版膠囊（貼底、左右各留 24）
Widget _wide({String label = '開始'}) => SizedBox(
  width: 342,
  height: 56,
  child: DecoratedBox(
    decoration: const ShapeDecoration(color: kLAccent, shape: StadiumBorder()),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.add, size: 22, color: kLBg),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
            color: kLBg,
          ),
        ),
      ],
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
    for (var i = 0; i < 12; i++) {
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

  const bottomCenter = Alignment.bottomCenter;
  const padCenter = EdgeInsets.only(bottom: 30);

  testWidgets('1 現況：右下角圓形 62', (t) async {
    await shoot(
      t,
      'p1-right-circle',
      _home(button: _circle(), note: '右下角 · 圓形 62'),
    );
  });

  testWidgets('2 右下角圓形 72（大一號）', (t) async {
    await shoot(
      t,
      'p2-right-circle-72',
      _home(button: _circle(size: 72, icon: 34), note: '右下角 · 圓形 72'),
    );
  });

  testWidgets('3 右下角圓角方形', (t) async {
    await shoot(
      t,
      'p3-right-squircle',
      _home(button: _squircle(), note: '右下角 · 圓角方形 62'),
    );
  });

  testWidgets('4 右下角描邊圓形', (t) async {
    await shoot(
      t,
      'p4-right-outlined',
      _home(button: _outlined(), note: '右下角 · 描邊圓形 62'),
    );
  });

  testWidgets('5 底部中間圓形 72', (t) async {
    await shoot(
      t,
      'p5-center-circle',
      _home(
        button: _circle(size: 72, icon: 34),
        align: bottomCenter,
        pad: padCenter,
        note: '底部中間 · 圓形 72',
      ),
    );
  });

  testWidgets('6 底部中間膠囊（＋ 開始）', (t) async {
    await shoot(
      t,
      'p6-center-pill',
      _home(
        button: _pill(),
        align: bottomCenter,
        pad: padCenter,
        note: '底部中間 · 膠囊',
      ),
    );
  });

  testWidgets('7 底部滿版膠囊', (t) async {
    await shoot(
      t,
      'p7-wide-pill',
      _home(
        button: _wide(),
        align: bottomCenter,
        pad: padCenter,
        note: '底部滿版 · 膠囊',
      ),
    );
  });

  testWidgets('8 底部中間圓角方形 72', (t) async {
    await shoot(
      t,
      'p8-center-squircle',
      _home(
        button: _squircle(size: 72, icon: 34, radius: 24),
        align: bottomCenter,
        pad: padCenter,
        note: '底部中間 · 圓角方形 72',
      ),
    );
  });
}
