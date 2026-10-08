import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/services/collage_compose.dart';
import 'package:markcut/services/collage_image_budget.dart';
import 'package:markcut/widgets/watermark_layer.dart';

Future<ui.Image> _source(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w / 2, h.toDouble()),
    Paint()..color = Colors.red,
  );
  canvas.drawRect(
    Rect.fromLTWH(w / 2, 0, w / 2, h.toDouble()),
    Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(w, h);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _png(int w, int h) async {
  final image = await _source(w, h);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'preview count shares one byte budget, while small collages stay sharp',
    () {
      expect(collagePreviewSide(2), 1600);
      for (var n = 1; n <= 120; n++) {
        final side = collagePreviewSide(n);
        expect(n * side * side * 4, lessThanOrEqualTo(kCollagePreviewBytes));
      }
    },
  );

  for (final free in [false, true]) {
    test(
      'bounded ${free ? 'free' : 'grid'} export preserves crop/pan and releases each group',
      () async {
        final original = await _source(80, 40);
        final preview = await _source(40, 20);
        final fit = CollageCellFit()
          ..zoom = 1.4
          ..panX = 4
          ..panY = -2
          ..crop = const Rect.fromLTWH(.2, 0, .8, 1);
        final layout = CollageLayout(
          free: free,
          cols: 2,
          rows: 1,
          order: [0, 0],
          fits: [fit, CollageCellFit()],
          items: [
            CollageFreeItem(
              img: 0,
              rect: const Rect.fromLTWH(0, 0, .7, 1),
              crop: const Rect.fromLTWH(.5, 0, .5, 1),
            ),
            CollageFreeItem(img: 0, rect: const Rect.fromLTWH(.4, .4, .6, .6)),
          ],
          canvasAspect: 2,
          lines: true,
          gapN: .025,
        );
        final fullFit = CollageCellFit()
          ..zoom = fit.zoom
          ..panX = fit.panX * 2
          ..panY = fit.panY * 2
          ..crop = fit.crop;
        final reference = await composeCollage(
          CollageLayout(
            free: free,
            cols: 2,
            rows: 1,
            order: layout.order,
            fits: [fullFit, CollageCellFit()],
            items: layout.items,
            canvasAspect: 2,
            lines: true,
            gapN: .025,
          ),
          [original],
          longSide: 80,
        );
        final decoded = <ui.Image>[];
        final actual = await composeCollageFromSources(
          layout,
          [preview],
          longSide: 80,
          // Force separate groups; each 80x40 source is 12,800 bytes.
          sourceByteBudget: 16000,
          decode: (index, maxSide) async {
            if (decoded.isNotEmpty) expect(decoded.last.debugDisposed, isTrue);
            final image = original.clone();
            decoded.add(image);
            return image;
          },
        );
        try {
          expect(decoded.length, 2);
          expect(decoded.every((image) => image.debugDisposed), isTrue);
          expect(
            (await actual.toByteData())!.buffer.asUint8List(),
            (await reference.toByteData())!.buffer.asUint8List(),
          );
          expect(original.debugDisposed, isFalse);
          expect(preview.debugDisposed, isFalse);
        } finally {
          original.dispose();
          preview.dispose();
          reference.dispose();
          actual.dispose();
        }
      },
    );
  }

  test(
    'export asks for source detail beyond a bounded preview and disposes on failure',
    () async {
      final preview = await _source(40, 20);
      final layout = CollageLayout(
        free: false,
        cols: 2,
        rows: 1,
        order: [0, 0],
        fits: [CollageCellFit()..zoom = 4, CollageCellFit()],
        items: [],
        canvasAspect: 1,
      );
      ui.Image? owned;
      var calls = 0;
      await expectLater(
        composeCollageFromSources(
          layout,
          [preview],
          decode: (_, side) async {
            calls++;
            expect(side, greaterThanOrEqualTo(1600));
            if (calls == 2) throw StateError('source missing');
            owned = preview.clone();
            return owned!;
          },
        ),
        throwsStateError,
      );
      expect(owned!.debugDisposed, isTrue);
      expect(preview.debugDisposed, isFalse);
      preview.dispose();
    },
  );

  testWidgets(
    '30 square photos retain at most 64MiB and grid gestures skip the shell',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      late Uint8List png;
      await t.runAsync(() async => png = await _png(1600, 1600));
      await t.pumpWidget(
        MaterialApp(
          home: CollageScreen(
            photos: [
              for (var i = 0; i < 30; i++) XFile.fromData(png, name: '$i.png'),
            ],
          ),
        ),
      );
      for (
        var i = 0;
        i < 200 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await t.pump();
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final state = t.state(find.byType(CollageScreen)) as CollageLayoutPeek;
      expect(state.images.length, 30);
      expect(
        state.images.fold<int>(
          0,
          (sum, image) => sum + image!.width * image.height * 4,
        ),
        lessThanOrEqualTo(kCollagePreviewBytes),
      );
      final wm = t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).settings;
      wm.text.enabled = false;
      final cell = find
          .byWidgetPredicate(
            (w) =>
                w is CustomPaint &&
                w.painter.runtimeType.toString() == '_CellPainter',
          )
          .first;
      await t.tap(cell);
      await t.pump();
      final center = t.getCenter(cell);
      // 指標編號交給測試框架自己配：前面的點擊已經用掉一號，
      // 寫死編號會跟自動配的撞號
      final a = await t.startGesture(center + const Offset(-14, 0));
      final b = await t.startGesture(center + const Offset(14, 0));
      await t.pump();
      final shells = <String>[];
      debugOnRebuildDirtyWidget = (element, _) {
        if (element.widget is CollageScreen ||
            element.widget is AppBar ||
            element.widget is TabBar) {
          shells.add(element.widget.runtimeType.toString());
        }
      };
      try {
        await a.moveBy(const Offset(-3, 0));
        await b.moveBy(const Offset(3, 0));
        await t.pump();
        expect(state.layout.fits.first.zoom, greaterThan(1));
        expect(shells, isEmpty);
      } finally {
        debugOnRebuildDirtyWidget = null;
        await a.up();
        await b.up();
      }
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );
}
