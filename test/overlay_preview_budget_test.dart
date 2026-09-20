import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/overlay_preview_policy.dart';
import 'package:markcut/services/watermark_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final fast in [true, false]) {
    test(
      'large ${fast ? "interactive" : "settled"} preview stays bounded RGBA',
      () async {
        final pixels = overlayPreviewMaxPixels(fast: fast);
        for (final full in [true, false]) {
          final part = await WatermarkRenderer.renderPart(
            WatermarkSettings(
              text: TextMark(text: 'markcut', sizeFrac: 4, x: -.5),
            ),
            1080,
            1920,
            ui.ImageByteFormat.png,
            fullCanvas: full,
            clipToCanvas: full,
            rawByteLimit: pixels * 4,
            maxRasterPixels: pixels,
          );
          expect(part, isNotNull);
          expect(part!.format, ui.ImageByteFormat.rawRgba);
          expect(part.bytes.length, part.width * part.height * 4);
          expect(
            part.bytes.length,
            lessThanOrEqualTo(fast ? 2 << 20 : 8 << 20),
          );
          if (full) {
            expect(part.fraction, [0, 0, 1, 1]);
          } else {
            expect(part.box.left, lessThan(0));
            expect(part.fraction[2], greaterThan(1));
          }
        }
      },
    );
  }

  test(
    'settled resolution follows native pixels in portrait and landscape',
    () {
      for (final (w, h) in [(720.0, 1280.0), (1280.0, 720.0)]) {
        expect(overlayPreviewShortSide(w, h, fast: false, text: false), 720);
        expect(overlayPreviewShortSide(w, h, fast: true, text: false), 540);
        expect(overlayPreviewShortSide(w, h, fast: true, text: true), 720);
      }
      expect(
        overlayPreviewShortSide(1080, 1920, fast: false, text: true),
        1080,
      );
      expect(overlayPreviewShortSide(0, 0, fast: false, text: true), 1080);
    },
  );

  test(
    'small settled parts use raw while larger parts keep PNG compression',
    () async {
      final s = WatermarkSettings(
        text: TextMark(text: 'markcut', colorValue: 0xff3baa88, opacity: .37),
      );
      final raw = await WatermarkRenderer.renderPart(
        s,
        720,
        1280,
        ui.ImageByteFormat.png,
        rawByteLimit: 1 << 20,
      );
      expect(raw, isNotNull);
      expect(raw!.format, ui.ImageByteFormat.rawRgba);
      expect(raw.bytes.length, raw.width * raw.height * 4);
      final png = await WatermarkRenderer.renderPart(
        s,
        720,
        1280,
        ui.ImageByteFormat.png,
        rawByteLimit: 16,
      );
      expect(png!.format, ui.ImageByteFormat.png);
      expect(png.bytes.take(4), [137, 80, 78, 71]);
      expect(png.fraction, raw.fraction);
      final codec = await ui.instantiateImageCodec(png.bytes);
      final decoded = (await codec.getNextFrame()).image;
      codec.dispose();
      try {
        final decodedBytes = (await decoded.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        expect(decodedBytes.length, raw.bytes.length);
        var maxDifference = 0;
        for (var i = 0; i < decodedBytes.length; i++) {
          final d = (decodedBytes[i] - raw.bytes[i]).abs();
          if (d > maxDifference) maxDifference = d;
        }
        expect(
          maxDifference,
          lessThanOrEqualTo(2),
          reason: 'switching format preserves premultiplied color and alpha',
        );
      } finally {
        decoded.dispose();
      }
    },
  );

  test(
    'retained off-canvas raster is bounded without clipping geometry',
    () async {
      final s = WatermarkSettings(
        text: TextMark(text: 'markcut', sizeFrac: 4, x: -1),
      );
      final part = await WatermarkRenderer.renderPart(
        s,
        720,
        1280,
        ui.ImageByteFormat.png,
        clipToCanvas: false,
        rawByteLimit: 1 << 20,
        maxRasterPixels: 128 * 1024,
      );
      expect(part, isNotNull);
      expect(part!.width * part.height, lessThanOrEqualTo(128 * 1024));
      expect(part.box.left, lessThan(0));
      expect(
        part.fraction[2],
        greaterThan(1),
        reason: 'keep pixels needed when dragging back',
      );
    },
  );

  test(
    'full-canvas raster is bounded and still fills the same canvas',
    () async {
      final part = await WatermarkRenderer.renderPart(
        WatermarkSettings(),
        1080,
        1920,
        ui.ImageByteFormat.png,
        fullCanvas: true,
        rawByteLimit: 1 << 20,
        maxRasterPixels: 128 * 1024,
      );
      expect(part!.width * part.height, lessThanOrEqualTo(128 * 1024));
      expect(part.fraction, [0, 0, 1, 1]);
    },
  );
}
