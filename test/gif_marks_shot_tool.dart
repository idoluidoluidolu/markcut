// GIF 頁修剪條「起點／終點標記」的版型比較（產圖工具，不是回歸測試）。
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/gif_marks_shot_tool.dart
//
// 沒設環境變數時整支略過。縮圖是假的色塊（測試環境抽不了影格），
// 其他（深色底、琥珀色、字體、尺寸）都照 App 現在的樣子。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_trim_strip.dart';

final _shotKey = GlobalKey();

/// 假縮圖：一排深淺不同的灰色格子，看得出「格」就好
Widget _fakeCells() => Row(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    for (var i = 0; i < 12; i++)
      Expanded(
        child: ColoredBox(
          color: Color.lerp(
            const Color(0xFF3A3A40),
            const Color(0xFF6A6A72),
            (i * 7 % 12) / 11,
          )!,
        ),
      ),
  ],
);

enum _Style { thin, bracket, triangle, dimOnly, thinDots }

/// 修剪條：整條 56 高、圓角 8；範圍 [xs, xe]，播放頭在 xp
Widget _strip(
  _Style s, {
  double xs = 0.10,
  double xe = 0.36,
  double xp = 0.30,
}) {
  const h = GifTrimStrip.stripHeight;
  return SizedBox(
    height: h,
    child: LayoutBuilder(
      builder: (context, cons) {
        final w = cons.maxWidth;
        final a = xs * w, b = xe * w, p = xp * w;
        final dim = Colors.black.withValues(alpha: 0.62);
        Widget line(
          double x, {
          double width = 2,
          double top = 0,
          double bottom = 0,
        }) => Positioned(
          left: x - width / 2,
          top: top,
          bottom: bottom,
          width: width,
          child: const ColoredBox(color: kSelect),
        );
        Widget tick(double x, {required bool left, required bool top}) =>
            Positioned(
              left: left ? x - 1 : x - 7,
              top: top ? 0 : null,
              bottom: top ? null : 0,
              width: 8,
              height: 2,
              child: const ColoredBox(color: kSelect),
            );
        Widget tri(double x, {required bool left}) => Positioned(
          left: x - 6,
          top: -7,
          width: 12,
          height: 7,
          child: CustomPaint(painter: _TriPainter(left: left)),
        );
        Widget dot(double x) => Positioned(
          left: x - 4,
          top: -9,
          width: 8,
          height: 8,
          child: const DecoratedBox(
            decoration: BoxDecoration(color: kSelect, shape: BoxShape.circle),
          ),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _fakeCells(),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: a,
              child: ColoredBox(color: dim),
            ),
            Positioned(
              left: b,
              top: 0,
              bottom: 0,
              right: 0,
              child: ColoredBox(color: dim),
            ),
            if (s == _Style.thin || s == _Style.thinDots) ...[line(a), line(b)],
            if (s == _Style.thinDots) ...[dot(a), dot(b)],
            if (s == _Style.bracket) ...[
              line(a, width: 2),
              line(b, width: 2),
              tick(a, left: true, top: true),
              tick(a, left: true, top: false),
              tick(b, left: false, top: true),
              tick(b, left: false, top: false),
            ],
            if (s == _Style.triangle) ...[
              line(a, width: 1.5),
              line(b, width: 1.5),
              tri(a, left: true),
              tri(b, left: false),
            ],
            // 播放頭：白 2px，跟現在一樣
            Positioned(
              left: p - 1,
              top: -2,
              bottom: -2,
              width: 2,
              child: const ColoredBox(color: kText),
            ),
          ],
        );
      },
    ),
  );
}

class _TriPainter extends CustomPainter {
  const _TriPainter({required this.left});
  final bool left;
  @override
  void paint(Canvas c, Size z) {
    final p = Path();
    if (left) {
      p.moveTo(0, 0);
      p.lineTo(z.width, 0);
      p.lineTo(z.width / 2 + 3, z.height);
      p.lineTo(z.width / 2 - 3, z.height);
    } else {
      p.moveTo(0, 0);
      p.lineTo(z.width, 0);
      p.lineTo(z.width / 2 + 3, z.height);
      p.lineTo(z.width / 2 - 3, z.height);
    }
    p.close();
    c.drawPath(p, Paint()..color = kSelect);
  }

  @override
  bool shouldRepaint(_TriPainter old) => old.left != left;
}

Widget _edgeBtn(String label) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
  decoration: BoxDecoration(
    color: kPanelHi,
    borderRadius: BorderRadius.circular(999),
    border: Border.all(color: kClipBorder),
  ),
  child: Text(
    label,
    style: const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: kText,
    ),
  ),
);

/// 一個版型一張：上面「設起點／設終點／長度」那一列，下面兩條修剪條——
/// 一條範圍正常（8.8 秒），一條範圍很短（0.4 秒，兩個標記貼很近）
Widget _card(String title, _Style s) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 12.5,
          color: kTextDim,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _edgeBtn('設起點'),
          const SizedBox(width: 8),
          _edgeBtn('設終點'),
          const Spacer(),
          const Text(
            '長度 8.8 秒',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: kText,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      _strip(s),
      const SizedBox(height: 14),
      Text(
        '同一種標記，範圍只有 0.4 秒（兩個標記貼在一起）',
        style: const TextStyle(fontSize: 11, color: kTextDim),
      ),
      const SizedBox(height: 6),
      _strip(s, xs: 0.30, xe: 0.325, xp: 0.31),
    ],
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
  });

  testWidgets('GIF 起訖標記五種 → gif-marks.png', (t) async {
    t.view.devicePixelRatio = 3.0;
    // 六張卡一次排完，畫布拉高（RepaintBoundary 拍的是整個視窗）
    t.view.physicalSize = const Size(1170, 4100);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: kBg,
            body: SafeArea(
              child: ListView(
                children: [
                  const SizedBox(height: 8),
                  _currentCard(),
                  _card('A · 細線：起訖各一條 2px 琥珀直線', _Style.thin),
                  _card('B · 括號：細線＋上下各一小截往內的橫線（[ ]）', _Style.bracket),
                  _card('C · 三角：細線＋上緣一個小三角指著起訖', _Style.triangle),
                  _card('D · 圓點：細線＋上緣一顆小圓點', _Style.thinDots),
                  _card('E · 只壓暗：不畫線，亮區的邊就是起訖', _Style.dimOnly),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
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
        '$out${Platform.pathSeparator}gif-marks.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}

/// 現況那一張：直接用 App 真的 GifTrimStrip（13px 把手），縮圖給 null 用底色
Widget _currentCard() => Padding(
  padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '現況：13px 琥珀把手＋上下 2px 框線',
        style: TextStyle(
          fontSize: 12.5,
          color: kTextDim,
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _edgeBtn('設起點'),
          const SizedBox(width: 8),
          _edgeBtn('設終點'),
          const Spacer(),
          const Text(
            '長度 8.8 秒',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: kText,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      GifTrimStrip(
        dur: 16.1,
        start: 1.6,
        end: 5.8,
        pos: ValueNotifier(4.8),
        cells: List<Uint8List?>.filled(12, null),
        onTapAt: (_) {},
        onScrubStart: (_) {},
        onScrubBy: (_) {},
        onScrubEnd: () {},
      ),
      const SizedBox(height: 14),
      const Text(
        '同一種標記，範圍只有 0.4 秒（兩個把手貼在一起）',
        style: TextStyle(fontSize: 11, color: kTextDim),
      ),
      const SizedBox(height: 6),
      GifTrimStrip(
        dur: 16.1,
        start: 4.8,
        end: 5.2,
        pos: ValueNotifier(5.0),
        cells: List<Uint8List?>.filled(12, null),
        onTapAt: (_) {},
        onScrubStart: (_) {},
        onScrubBy: (_) {},
        onScrubEnd: () {},
      ),
    ],
  ),
);
