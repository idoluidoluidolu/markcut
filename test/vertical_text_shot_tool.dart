// 直式文字樣張（產圖工具，不是回歸測試）：用真的共用畫家 paintMarkGlyphs
// ＋真的字型檔畫一排直式，看標點轉向、字身置中、欄距、底色留白對不對。
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub --no-test-assets test/vertical_text_shot_tool.dart
//
// 沒設環境變數時整支略過。洋紅細框＝measureMark 量到的版面框
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/text_mark_painter.dart';

const _files = <String, String>{
  'NotoSansTC': 'NotoSansTC.ttf',
  'NotoSerifTC': 'NotoSerifTC.ttf',
  'OpenHuninn': 'jf-openhuninn.ttf',
  'LXGWWenKaiTC': 'LXGWWenKaiTC.ttf',
  'Yozai': 'Yozai.ttf',
  'FusionPixel': 'FusionPixel.ttf',
  'Montserrat': 'Montserrat.ttf',
  'Pacifico': 'Pacifico.ttf',
};

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '產圖工具，要給輸出資料夾才會跑');
    return;
  }
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    Directory(out).createSync(recursive: true);
    for (final e in _files.entries) {
      // 縫合像素改成點了才下載，不在 assets：從 markcut-fonts 的 clone 拿
      var file = File('assets/fonts/${e.value}');
      final dl = Platform.environment['MARKCUT_FONTS_DIR'];
      if (!file.existsSync() && dl != null && dl.isNotEmpty) {
        file = File('$dl${Platform.pathSeparator}${e.value}');
      }
      final data = file.readAsBytesSync();
      final loader = FontLoader(e.key)
        ..addFont(Future.value(ByteData.view(data.buffer)));
      await loader.load();
    }
  });

  TextMark mk(
    String text, {
    String font = 'NotoSansTC',
    void Function(TextMark)? f,
  }) {
    final t = TextMark(
      text: text,
      fontFamily: font,
      vertical: true,
      opacity: 1,
    );
    f?.call(t);
    return t;
  }

  final samples = <(String, TextMark)>[
    ('預設', mk('@我的浮水印')),
    ('兩行 靠上', mk('浮水印\n剪輯')),
    ('兩行 置中', mk('浮水印\n剪輯', f: (t) => t.alignment = ui.TextAlign.center)),
    ('兩行 靠下', mk('浮水印\n剪輯', f: (t) => t.alignment = ui.TextAlign.right)),
    ('括號', mk('「浮水印」\n（剪輯）…～')),
    ('拉丁', mk('MarkCut 2026')),
    ('底色', mk('我的頻道', f: (t) => t.bg = true)),
    (
      '描邊 間距30',
      mk(
        '我的頻道',
        f: (t) {
          t.outline = true;
          t.outlineColorValue = 0xFFE53935;
          t.spacing = 0.3;
        },
      ),
    ),
    ('間距-20', mk('字距負值', f: (t) => t.spacing = -0.2)),
    ('思源宋', mk('浮水印，剪輯。', font: 'NotoSerifTC')),
    ('粉圓', mk('「粉圓」，好吃。', font: 'OpenHuninn')),
    ('文楷', mk('文楷\n直排「書」', font: 'LXGWWenKaiTC')),
    ('悠哉', mk('悠哉、悠哉。', font: 'Yozai')),
    ('像素', mk('像素「直排」', font: 'FusionPixel')),
    ('Montserrat', mk('Hello 你好', font: 'Montserrat')),
    ('Pacifico', mk('Love 愛', font: 'Pacifico')),
    ('emoji 全形空白', mk('早安　😀咖啡')),
    (
      '底色 兩行 置中',
      mk(
        '浮水印\n剪輯工具',
        f: (t) {
          t.bg = true;
          t.alignment = ui.TextAlign.center;
        },
      ),
    ),
  ];

  test('直式樣張 → vertical_samples.png', () async {
    const cols = 6;
    const cellW = 300.0, cellH = 520.0, fontSize = 56.0;
    final rows = (samples.length / cols).ceil();
    final w = cellW * cols, h = cellH * rows;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w, h),
      ui.Paint()..color = const ui.Color(0xFF5A6470),
    );
    for (var i = 0; i < samples.length; i++) {
      final (label, t) = samples[i];
      final cx = (i % cols) * cellW, cy = (i ~/ cols) * cellH;
      canvas.drawRect(
        ui.Rect.fromLTWH(cx + 4, cy + 4, cellW - 8, cellH - 8),
        ui.Paint()
          ..color = const ui.Color(0x33FFFFFF)
          ..style = ui.PaintingStyle.stroke,
      );
      TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(
              fontFamily: 'NotoSansTC',
              fontSize: 20,
              color: ui.Color(0xFFFFE082),
            ),
          ),
          textDirection: TextDirection.ltr,
        )
        ..layout()
        ..paint(canvas, ui.Offset(cx + 12, cy + 10));
      final m = measureMark(t, fontSize);
      final c = ui.Offset(cx + cellW / 2, cy + 44 + (cellH - 52) / 2);
      final left = c.dx - m.width / 2, top = c.dy - m.height / 2;
      if (t.bg) {
        final (h: padH, v: padV) = markBgPadding(t, fontSize);
        canvas.drawRRect(
          ui.RRect.fromRectAndRadius(
            ui.Rect.fromLTWH(
              left - padH,
              top - padV,
              m.width + padH * 2,
              m.height + padV * 2,
            ),
            ui.Radius.circular(fontSize * t.bgCorner),
          ),
          ui.Paint()..color = t.bgColor.withValues(alpha: t.bgOpacity),
        );
      }
      paintMarkGlyphs(canvas, t, fontSize, ui.Offset(left, top));
      canvas.drawRect(
        ui.Rect.fromLTWH(left, top, m.width, m.height),
        ui.Paint()
          ..color = const ui.Color(0xFFFF00FF)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final pic = rec.endRecording();
    final img = await pic.toImage(w.toInt(), h.toInt());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File(
      '$out/vertical_samples.png',
    ).writeAsBytesSync(png!.buffer.asUint8List());
    img.dispose();
    pic.dispose();
  });

  test('直式平鋪 → vertical_tiled.png', () async {
    const w = 720.0, h = 1280.0;
    final t = mk(
      '@我的浮水印',
      f: (t) {
        t.tiled = true;
        t.rotation = -20;
        t.opacity = 0.6;
      },
    );
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w, h),
      ui.Paint()..color = const ui.Color(0xFF5A6470),
    );
    paintTextTiled(canvas, t, t.sizeFrac * 0.5 * math.min(w, h), w, h);
    final pic = rec.endRecording();
    final img = await pic.toImage(w.toInt(), h.toInt());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$out/vertical_tiled.png').writeAsBytesSync(png!.buffer.asUint8List());
    img.dispose();
    pic.dispose();
  });
}
