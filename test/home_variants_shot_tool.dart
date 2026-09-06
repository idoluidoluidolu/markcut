// 首頁下半部四格的版型比較（暫時的產圖工具，不是回歸測試）。
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/home_variants_shot_tool.dart
//
// 沒設環境變數時整支略過。用的是 App 真的色票、真的 logo、真的字體，
// 但畫面是這支自己組的（不動 lib/），純粹給人比較用。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/theme.dart';

final _shotKey = GlobalKey();

const _labels = ['浮水印', '照片拼圖', 'GIF', '剪輯'];
const _icons = [
  Icons.branding_watermark_outlined,
  Icons.grid_view_rounded,
  Icons.gif_box_outlined,
  Icons.smart_display_outlined,
];

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

/// 描邊版的邊線
const _side = BorderSide(color: kLBorder, width: 1.5);

/// 一格：方塊＋名稱。[inside]＝名稱放在方塊裡面
Widget _tile({
  required IconData icon,
  required String label,
  required double iconSize,
  bool primary = false,
  bool flat = false,
  bool inside = false,
  double aspect = 1,
  bool outline = false,
  bool circle = false,
  double radius = 20,
  bool allDark = false,
  bool bare = false,
  bool cornerLabel = false,
}) {
  final bg = bare
      ? Colors.transparent
      : allDark
      ? kLAccent
      : outline
      ? Colors.transparent
      : (flat ? kLTile : (primary ? kLAccent : kLTile));
  final fg = allDark
      ? kLBg
      : bare || outline
      ? kLText
      : (flat ? kLText : (primary ? kLBg : kLText));
  final box = AspectRatio(
    aspectRatio: aspect,
    child: DecoratedBox(
      decoration: ShapeDecoration(
        color: bg,
        shape: circle
            ? CircleBorder(side: outline ? _side : BorderSide.none)
            : RoundedSuperellipseBorder(
                borderRadius: BorderRadius.all(Radius.circular(radius)),
                side: outline ? _side : BorderSide.none,
              ),
      ),
      child: cornerLabel
          ? Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.topRight,
                    child: Icon(icon, size: iconSize, color: fg),
                  ),
                  const Spacer(),
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: fg,
                    ),
                  ),
                ],
              ),
            )
          : inside
          ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: iconSize, color: fg),
                const SizedBox(height: 10),
                Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                    color: fg,
                  ),
                ),
              ],
            )
          : Center(
              child: Icon(icon, size: iconSize, color: fg),
            ),
    ),
  );
  if (inside || cornerLabel) return box;
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      box,
      const SizedBox(height: 10),
      Text(
        label,
        maxLines: 1,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: kLText,
        ),
      ),
    ],
  );
}

Widget _grid2x2({
  required double iconSize,
  bool flat = false,
  bool inside = false,
}) => Column(
  children: [
    for (var r = 0; r < 2; r++) ...[
      if (r > 0) const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var c = 0; c < 2; c++) ...[
            if (c > 0) const SizedBox(width: 12),
            Expanded(
              child: _tile(
                icon: _icons[r * 2 + c],
                label: _labels[r * 2 + c],
                iconSize: iconSize,
                primary: r == 0 && c == 0,
                flat: flat,
                inside: inside,
              ),
            ),
          ],
        ],
      ),
    ],
  ],
);

Widget _row4({
  required double iconSize,
  double aspect = 1,
  bool inside = false,
}) => Row(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    for (var i = 0; i < 4; i++) ...[
      if (i > 0) const SizedBox(width: 12),
      Expanded(
        child: _tile(
          icon: _icons[i],
          label: _labels[i],
          iconSize: iconSize,
          primary: i == 0,
          inside: inside,
          aspect: aspect,
        ),
      ),
    ],
  ],
);

Widget _page(Widget tiles) => Scaffold(
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
  body: SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Center(
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
          ),
          tiles,
        ],
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

  Future<void> shoot(WidgetTester t, String name, Widget tiles) async {
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
          home: LightPage(child: _page(tiles)),
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

  Widget grid({
    required double iconSize,
    bool outline = false,
    bool circle = false,
    double radius = 20,
    bool inside = false,
    bool flat = false,
    bool allDark = false,
    bool cornerLabel = false,
  }) => Column(
    children: [
      for (var r = 0; r < 2; r++) ...[
        if (r > 0) const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var c = 0; c < 2; c++) ...[
              if (c > 0) const SizedBox(width: 12),
              Expanded(
                child: _tile(
                  icon: _icons[r * 2 + c],
                  label: _labels[r * 2 + c],
                  iconSize: iconSize,
                  primary: r == 0 && c == 0,
                  flat: flat,
                  inside: inside,
                  outline: outline,
                  circle: circle,
                  radius: radius,
                  allDark: allDark,
                  cornerLabel: cornerLabel,
                ),
              ),
            ],
          ],
        ),
      ],
    ],
  );

  Widget row4({
    required double iconSize,
    bool outline = false,
    bool circle = false,
    double radius = 20,
    bool inside = false,
    double aspect = 1,
    bool bare = false,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < 4; i++) ...[
        if (i > 0) const SizedBox(width: 12),
        Expanded(
          child: _tile(
            icon: _icons[i],
            label: _labels[i],
            iconSize: iconSize,
            primary: i == 0,
            inside: inside,
            outline: outline,
            circle: circle,
            radius: radius,
            aspect: aspect,
            bare: bare,
          ),
        ),
      ],
    ],
  );

  /// 主格跨整排、下面三個小格
  Widget heroPlusThree() => Column(
    children: [
      _tile(
        icon: _icons[0],
        label: _labels[0],
        iconSize: 44,
        primary: true,
        cornerLabel: true,
        aspect: 2.6,
      ),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 1; i < 4; i++) ...[
            if (i > 1) const SizedBox(width: 12),
            Expanded(
              child: _tile(
                icon: _icons[i],
                label: _labels[i],
                iconSize: 30,
                inside: true,
              ),
            ),
          ],
        ],
      ),
    ],
  );

  /// 一個大圓角框、四等分、細線分隔
  Widget segmented() => DecoratedBox(
    decoration: const ShapeDecoration(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.all(Radius.circular(22)),
        side: BorderSide(color: kLBorder, width: 1.5),
      ),
    ),
    child: SizedBox(
      height: 92,
      child: Row(
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0)
              const SizedBox(width: 1.5, child: ColoredBox(color: kLBorder)),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_icons[i], size: 26, color: kLText),
                  const SizedBox(height: 8),
                  Text(
                    _labels[i],
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: kLText,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );

  testWidgets('I 主格跨整排＋三小格', (t) async {
    await shoot(t, 'v-i-hero3', heroPlusThree());
  });

  testWidgets('J 一排四個、沒有方塊', (t) async {
    await shoot(t, 'v-j-row-bare', row4(iconSize: 34, bare: true));
  });

  testWidgets('K 2×2 四格全黑', (t) async {
    await shoot(t, 'v-k-2x2-alldark', grid(iconSize: 56, allDark: true));
  });

  testWidgets('L 一排四格、扁方塊', (t) async {
    await shoot(
      t,
      'v-l-row-wide',
      row4(iconSize: 28, aspect: 1.35, inside: true),
    );
  });

  testWidgets('M 一排四格、直立膠囊', (t) async {
    await shoot(
      t,
      'v-m-row-pill',
      row4(iconSize: 28, aspect: 0.7, inside: true, radius: 999),
    );
  });

  testWidgets('N 2×2 描邊＋淡底', (t) async {
    await shoot(
      t,
      'v-n-2x2-flatgrid',
      grid(iconSize: 52, flat: true, radius: 20),
    );
  });

  testWidgets('O 2×2 名稱在左下、圖示在右上', (t) async {
    await shoot(t, 'v-o-2x2-corner', grid(iconSize: 34, cornerLabel: true));
  });

  testWidgets('P 一整條分段控制器', (t) async {
    await shoot(t, 'v-p-segmented', segmented());
  });

  testWidgets('Q 2×2 圖示超大', (t) async {
    await shoot(t, 'v-q-2x2-icon76', grid(iconSize: 76));
  });

  testWidgets('E 2×2 描邊、不填色', (t) async {
    await shoot(t, 'v-e-2x2-outline', grid(iconSize: 52, outline: true));
  });

  testWidgets('F 2×2 大圓角（radius 36）', (t) async {
    await shoot(t, 'v-f-2x2-round36', grid(iconSize: 56, radius: 36));
  });

  testWidgets('G 一排四個圓形', (t) async {
    await shoot(t, 'v-g-row-circle', row4(iconSize: 30, circle: true));
  });

  testWidgets('H 一排四格、大方塊貼滿（間距 6）', (t) async {
    await shoot(
      t,
      'v-h-row-tight',
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 4; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: _tile(
                icon: _icons[i],
                label: _labels[i],
                iconSize: 34,
                primary: i == 0,
                inside: true,
                aspect: 0.86,
                radius: 14,
              ),
            ),
          ],
        ],
      ),
    );
  });

  testWidgets('A 2×2 圖示放大', (t) async {
    await shoot(t, 'v-a-2x2-bigicon', _grid2x2(iconSize: 56));
  });

  testWidgets('B 2×2 名稱放進方塊', (t) async {
    await shoot(t, 'v-b-2x2-inside', _grid2x2(iconSize: 44, inside: true));
  });

  testWidgets('C 2×2 四格同色', (t) async {
    await shoot(t, 'v-c-2x2-flat', _grid2x2(iconSize: 56, flat: true));
  });

  testWidgets('D 一排四格、方塊直立、名稱在裡面', (t) async {
    await shoot(
      t,
      'v-d-row-tall',
      _row4(iconSize: 28, aspect: 0.78, inside: true),
    );
  });
}
