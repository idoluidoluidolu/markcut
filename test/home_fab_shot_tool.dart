// 首頁改成「右下角＋號叫出選單」的版型比較（產圖工具，不是回歸測試）。
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

const _wm = Icons.branding_watermark_outlined;
const _collage = Icons.grid_view_rounded;
const _gif = Icons.gif_box_outlined;
const _cut = Icons.smart_display_outlined;

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

/// 首頁本體：logo 置中，下面空著，右下角一顆黑色＋
Widget _home({required bool dim, Widget? overlay, bool showFab = true}) =>
    Scaffold(
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
          if (dim)
            const Positioned.fill(child: ColoredBox(color: Color(0x66121216))),
          ?overlay,
          if (showFab) Positioned(right: 22, bottom: 30, child: _fab()),
        ],
      ),
    );

Widget _fab({bool open = false}) => DecoratedBox(
  decoration: const ShapeDecoration(color: kLAccent, shape: CircleBorder()),
  child: SizedBox(
    width: 62,
    height: 62,
    child: Center(
      child: Transform.rotate(
        angle: open ? 0.785 : 0,
        child: const Icon(Icons.add, size: 30, color: kLBg),
      ),
    ),
  ),
);

/// 一列：圖示方塊＋名稱（＋副標／箭頭）
Widget _row(
  IconData icon,
  String label, {
  String? sub,
  bool chevron = false,
  double h = 60,
}) => SizedBox(
  height: h,
  child: Row(
    children: [
      Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: const ShapeDecoration(
          color: kLTile,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        child: Icon(icon, size: 22, color: kLText),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: kLText,
              ),
            ),
            if (sub != null) ...[
              const SizedBox(height: 3),
              Text(sub, style: const TextStyle(fontSize: 12, color: kLTextDim)),
            ],
          ],
        ),
      ),
      if (chevron)
        const Icon(Icons.chevron_right, size: 20, color: Color(0xFFB0B0BA)),
    ],
  ),
);

/// 底部浮起的白色面板
Widget _sheet(List<Widget> children) => Align(
  alignment: Alignment.bottomCenter,
  child: DecoratedBox(
    decoration: const ShapeDecoration(
      color: kLBg,
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 5,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFD6D6DE),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          ...children,
        ],
      ),
    ),
  ),
);

/// 小分類的膠囊（縮排在主項底下）
Widget _chip(String label) => Container(
  margin: const EdgeInsets.only(right: 8),
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
  decoration: const ShapeDecoration(color: kLTile, shape: StadiumBorder()),
  child: Text(
    label,
    style: const TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      color: kLText,
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

  testWidgets('0 收起來的首頁', (t) async {
    await shoot(t, 'fab-0-closed', _home(dim: false));
  });

  testWidgets('A 底部表單三列，各列有箭頭（點了再進第二層）', (t) async {
    await shoot(
      t,
      'fab-a-sheet-chevron',
      _home(
        dim: true,
        showFab: false,
        overlay: _sheet([
          _row(_wm, '浮水印', chevron: true),
          _row(_collage, '照片拼圖', chevron: true),
          _row(_gif, 'GIF', chevron: true),
        ]),
      ),
    );
  });

  testWidgets('B 底部表單，每項下面直接把小分類攤開', (t) async {
    await shoot(
      t,
      'fab-b-sheet-expanded',
      _home(
        dim: true,
        showFab: false,
        overlay: _sheet([
          _row(_wm, '浮水印', h: 50),
          Padding(
            padding: const EdgeInsets.only(left: 54, bottom: 16),
            child: Row(children: [_chip('照片'), _chip('影片'), _chip('批次')]),
          ),
          _row(_collage, '照片拼圖', h: 50),
          Padding(
            padding: const EdgeInsets.only(left: 54, bottom: 16),
            child: Row(children: [_chip('九宮格'), _chip('自由排')]),
          ),
          _row(_gif, 'GIF', h: 50),
          Padding(
            padding: const EdgeInsets.only(left: 54),
            child: Row(children: [_chip('影片轉'), _chip('從相簿'), _chip('從檔案')]),
          ),
        ]),
      ),
    );
  });

  testWidgets('C ＋號旁邊彈出三顆小圓鈕（速撥）', (t) async {
    await shoot(
      t,
      'fab-c-speeddial',
      _home(
        dim: true,
        showFab: false,
        overlay: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 22, bottom: 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (ic, label) in const [
                  (_wm, '浮水印'),
                  (_collage, '照片拼圖'),
                  (_gif, 'GIF'),
                ]) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: const ShapeDecoration(
                            color: kLBg,
                            shape: StadiumBorder(),
                          ),
                          child: Text(
                            label,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: kLText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        DecoratedBox(
                          decoration: const ShapeDecoration(
                            color: kLBg,
                            shape: CircleBorder(),
                          ),
                          child: SizedBox(
                            width: 50,
                            height: 50,
                            child: Icon(ic, size: 24, color: kLText),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                _fab(open: true),
              ],
            ),
          ),
        ),
      ),
    );
  });

  testWidgets('D 底部表單三列＋副標說明', (t) async {
    await shoot(
      t,
      'fab-d-sheet-sub',
      _home(
        dim: true,
        showFab: false,
        overlay: _sheet([
          _row(_wm, '浮水印', sub: '照片、影片，單支或整批', chevron: true, h: 68),
          _row(_collage, '照片拼圖', sub: '多張照片拼成一張', chevron: true, h: 68),
          _row(_gif, 'GIF', sub: '影片轉 GIF，或匯入現成的', chevron: true, h: 68),
        ]),
      ),
    );
  });

  testWidgets('E 四項（剪輯也放進來）', (t) async {
    await shoot(
      t,
      'fab-e-sheet-four',
      _home(
        dim: true,
        showFab: false,
        overlay: _sheet([
          _row(_wm, '浮水印', chevron: true),
          _row(_collage, '照片拼圖', chevron: true),
          _row(_gif, 'GIF', chevron: true),
          _row(_cut, '剪輯', sub: '開一條空軌道'),
        ]),
      ),
    );
  });

  testWidgets('F 第二層長怎樣（浮水印 → 照片／影片）', (t) async {
    await shoot(
      t,
      'fab-f-second-level',
      _home(
        dim: true,
        showFab: false,
        overlay: _sheet([
          Row(
            children: [
              const Icon(Icons.chevron_left, size: 22, color: kLText),
              const SizedBox(width: 6),
              const Text(
                '浮水印',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                  color: kLText,
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 10),
          _row(Icons.photo_outlined, '照片', sub: '單張或整批'),
          _row(Icons.movie_outlined, '影片', sub: '單支或整批'),
        ]),
      ),
    );
  });
}
