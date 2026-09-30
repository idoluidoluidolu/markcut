import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/text_mark_painter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'alignment survives copy and JSON while old drafts keep their layout',
    () {
      expect(TextMark.fromJson({'text': 'a\nb'}).alignment, ui.TextAlign.left);
      expect(
        TextMark.fromJson({'alignment': 'invalid'}).alignment,
        ui.TextAlign.left,
      );
      for (final align in [
        ui.TextAlign.left,
        ui.TextAlign.center,
        ui.TextAlign.right,
      ]) {
        final t = TextMark(text: 'long line\nshort', alignment: align);
        expect(t.copy().alignment, align);
        expect(TextMark.fromJson(t.toJson()).text, 'long line\nshort');
      }
    },
  );

  test(
    'the shared preview/export painter positions multiline glyphs and invalidates caches',
    () async {
      final t = TextMark(text: 'MMMM\nM', shadow: false, weight: 0, opacity: 1);
      final lefts = <int>[];
      for (final align in [
        ui.TextAlign.left,
        ui.TextAlign.center,
        ui.TextAlign.right,
      ]) {
        final old = MarkGlyphPainter(t, 20);
        t.alignment = align;
        if (align != ui.TextAlign.left) {
          expect(MarkGlyphPainter(t, 20).shouldRepaint(old), isTrue);
        }
        final size = measureMark(t, 20);
        final rec = ui.PictureRecorder();
        paintMarkGlyphs(ui.Canvas(rec), t, 20, const ui.Offset(8, 8));
        final picture = rec.endRecording();
        final img = await picture.toImage(200, 120);
        final pixels = (await img.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var left = 200;
        for (var y = (8 + size.height / 2).ceil(); y < 120; y++) {
          for (var x = 0; x < 200; x++) {
            if (pixels.getUint8((y * 200 + x) * 4 + 3) > 0 && x < left) {
              left = x;
            }
          }
        }
        lefts.add(left);
        img.dispose();
        picture.dispose();
      }
      expect(lefts[0], lessThan(lefts[1]));
      expect(lefts[1], lessThan(lefts[2]));
      expect(lefts[2], lessThan(200));
      clearGlyphCache();
    },
  );
}
