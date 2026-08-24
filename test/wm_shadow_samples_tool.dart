// 產「陰影濃度×模糊」對照樣張的工具（不是回歸測試）：
//   flutter test test/wm_shadow_samples_tool.dart
// 會把 shadow_samples.png 寫到系統暫存目錄，路徑印在輸出。
// 用真的 paintMarkGlyphs＋真的思源黑體，看到什麼就是成品什麼樣。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/text_mark_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('產陰影對照樣張', () async {
    final data = File('assets/fonts/NotoSansTC.ttf').readAsBytesSync();
    final loader = FontLoader('NotoSansTC')
      ..addFont(Future.value(ByteData.view(data.buffer)));
    await loader.load();

    // 每格一種組合：(濃度, 模糊)
    const combos = <(double, double)>[
      (0.35, 0.0),
      (0.55, 0.0),
      (0.80, 0.0),
      (0.35, 0.04),
      (0.55, 0.04),
      (0.80, 0.04),
      (0.35, 0.08),
      (0.55, 0.08),
      (0.80, 0.08),
      (0.35, 0.14),
      (0.55, 0.14),
      (0.80, 0.14),
    ];
    const cellW = 560.0, cellH = 210.0, cols = 3;
    final rows = (combos.length / cols).ceil();
    final w = cellW * cols, h = cellH * rows;

    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    // 底：亮色照片常見的情境（陰影就是為了亮底看得清）
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, w, h),
      ui.Paint()
        ..shader = ui.Gradient.linear(
          ui.Offset.zero,
          ui.Offset(w, h),
          const [ui.Color(0xFFF2EFE9), ui.Color(0xFFCFD8DC)],
        ),
    );

    for (var i = 0; i < combos.length; i++) {
      final (op, blur) = combos[i];
      final cx = (i % cols) * cellW, cy = (i ~/ cols) * cellH;
      canvas.drawRect(
        ui.Rect.fromLTWH(cx + 8, cy + 8, cellW - 16, cellH - 16),
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..color = const ui.Color(0x33000000),
      );
      final t = TextMark(
        text: '@我的浮水印',
        opacity: 0.55,
        shadow: true,
        shadowOpacity: op,
        shadowBlur: blur,
      );
      const fontSize = 64.0;
      final m = measureMark(t, fontSize);
      paintMarkGlyphs(
        canvas,
        t,
        fontSize,
        ui.Offset(cx + (cellW - m.width) / 2, cy + 46),
      );
      // 標籤
      final label = TextPainter(
        text: TextSpan(
          text: '濃度 ${op.toStringAsFixed(2)}　模糊 ${blur.toStringAsFixed(2)}',
          style: const TextStyle(
            fontFamily: 'NotoSansTC',
            fontSize: 22,
            color: ui.Color(0xFF37474F),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, ui.Offset(cx + 24, cy + cellH - 46));
    }

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    final out = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}shadow_samples.png',
    );
    out.writeAsBytesSync(png!.buffer.asUint8List());
    // ignore: avoid_print
    print('樣張：${out.path}');
  });
}
