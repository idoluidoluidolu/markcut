import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/nav.dart';
import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/screens/crop_screen.dart';
import 'package:markcut/services/collage_compose.dart';
import 'package:markcut/services/draft_assets.dart';

const _rightHalf = Rect.fromLTWH(0.5, 0, 0.5, 1);

Future<ui.Image> _source() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, 40, 40), Paint()..color = Colors.red);
  c.drawRect(const Rect.fromLTWH(40, 0, 40, 40), Paint()..color = Colors.blue);
  final pic = rec.endRecording();
  final image = await pic.toImage(80, 40);
  pic.dispose();
  return image;
}

Future<int> _pixel(ui.Image image, int x, int y) async {
  final bytes = (await image.toByteData())!.buffer.asUint8List();
  final i = (y * image.width + x) * 4;
  return Color.fromARGB(
    bytes[i + 3],
    bytes[i],
    bytes[i + 1],
    bytes[i + 2],
  ).toARGB32();
}

Future<void> _wait(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 30));
  }
  expect(ready(), isTrue, reason: 'Timed out waiting for asynchronous UI');
  await t.pump(const Duration(milliseconds: 400));
}

CollageLayoutPeek _peek(WidgetTester t) =>
    t.state(find.byType(CollageScreen)) as CollageLayoutPeek;

Future<void> _open(WidgetTester t, Map<String, dynamic> draft) async {
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: TargetPlatform.iOS),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push(
              context,
              editRoute(builder: (_) => CollageScreen(restore: draft)),
            ),
            child: const Text('首頁'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('首頁'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await _wait(
    t,
    () =>
        _peek(t).images.length == 2 &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy, malformed and out-of-bounds crop data have safe fallbacks', () {
    for (final value in [
      null,
      'bad',
      [0, 0],
      [0, 0, '1', 1],
      [0, 0, -1, 1],
      [double.nan, 0, 1, 1],
      [2, 2, 1, 1],
    ]) {
      expect(collageCropFromJson(value), kCollageFullCrop);
    }
    expect(
      collageCropFromJson([-0.5, 0, 1, 1]),
      const Rect.fromLTWH(0, 0, 0.5, 1),
    );
    expect(collageCropFromJson(collageCropToJson(_rightHalf)), _rightHalf);
  });

  test(
    'crop keeps free photo center and pixel aspect on different canvases',
    () {
      for (final aspect in [1.0, 9 / 16, 16 / 9]) {
        const before = Rect.fromLTWH(0.2, 0.1, 0.6, 0.8);
        final after = collageFitCropRect(before, 2, aspect);
        expect(after.center.dx, closeTo(before.center.dx, 1e-10));
        expect(after.center.dy, closeTo(before.center.dy, 1e-10));
        expect(after.width * aspect / after.height, closeTo(2, 1e-10));
        expect(after.width, lessThanOrEqualTo(before.width));
        expect(after.height, lessThanOrEqualTo(before.height));
      }
    },
  );

  test(
    'grid pan and zoom cannot reveal pixels outside selected crop',
    () async {
      final source = await _source();
      try {
        final fit = CollageCellFit()
          ..crop = _rightHalf
          ..zoom = 2
          ..panX = -999
          ..panY = 999;
        collageClampFit(source, fit, 1);
        final src = collageSrcRect(source, fit, 1);
        expect(src, const Rect.fromLTWH(40, 20, 20, 20));
        expect(
          collageCoverSrc(source, 1, crop: _rightHalf),
          const Rect.fromLTWH(40, 0, 40, 40),
        );
      } finally {
        source.dispose();
      }
    },
  );

  for (final free in [false, true]) {
    test(
      '${free ? 'free' : 'grid'} composition crops only selected photo',
      () async {
        final source = await _source();
        final layout = CollageLayout(
          free: free,
          cols: 2,
          rows: 1,
          order: [0, 0],
          fits: [CollageCellFit()..crop = _rightHalf, CollageCellFit()],
          items: [
            CollageFreeItem(
              img: 0,
              rect: const Rect.fromLTWH(0, 0, 0.5, 1),
              crop: _rightHalf,
            ),
            CollageFreeItem(img: 0, rect: const Rect.fromLTWH(0.5, 0, 0.5, 1)),
          ],
          canvasAspect: 2,
        );
        final image = await composeCollage(layout, [source], longSide: 80);
        try {
          expect(await _pixel(image, 5, 20), Colors.blue.toARGB32());
          expect(await _pixel(image, 45, 20), Colors.red.toARGB32());
          expect(await _pixel(source, 5, 20), Colors.red.toARGB32());
          expect(source.width, 80);
        } finally {
          image.dispose();
          source.dispose();
        }
      },
    );

    testWidgets(
      '${free ? 'free' : 'grid'} crop, reopen, cancel and draft restore',
      (t) async {
        SharedPreferences.setMockInitialValues({});
        final root = Directory.systemTemp.createTempSync(
          'markcut_collage_crop_',
        );
        final support = Directory('${root.path}/support')..createSync();
        DraftAssets.supportDirOverride = support;
        DraftAssets.pickerRootsOverride = [];
        await t.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() async {
          DraftAssets.supportDirOverride = null;
          DraftAssets.pickerRootsOverride = null;
          await t.binding.setSurfaceSize(null);
          root.deleteSync(recursive: true);
        });
        late String path;
        await t.runAsync(() async {
          final image = await _source();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          path = '${root.path}/original.png';
          File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        final original = File(path).readAsBytesSync();
        await _open(t, {
          'photos': [path, path],
          'free': free,
          'cols': 2,
          'rows': 1,
          'aspect': 1.0,
          'order': [0, 1],
          'freeItems': [
            {'img': 0, 'l': 0.1, 't': 0.1, 'w': 0.6, 'h': 0.3},
            {'img': 1, 'l': 0.7, 't': 0.7, 'w': 0.2, 'h': 0.1},
          ],
        });
        final paints = find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              w.painter.runtimeType.toString() ==
                  (free ? '_FreePainter' : '_CellPainter'),
        );
        if (free) {
          final box = t.getRect(paints.first);
          await t.tapAt(
            box.topLeft + Offset(box.width * 0.4, box.height * 0.25),
          );
        } else {
          await t.tap(paints.first);
        }
        await t.pump();
        final cropButton = find.byKey(const ValueKey('collage-crop-photo'));
        expect(cropButton, findsOneWidget);
        final before = _peek(
          t,
        ).layout.items.singleWhere((i) => i.img == 0).rect;
        final neighbor = _peek(
          t,
        ).layout.items.singleWhere((i) => i.img == 1).rect;
        await t.tap(cropButton);
        await _wait(t, () => find.byType(CropScreen).evaluate().isNotEmpty);
        expect(
          t.widget<CropScreen>(find.byType(CropScreen)).initial,
          kCollageFullCrop,
        );
        // The crop route returns normalized coordinates, without replacing the original.
        Navigator.of(t.element(find.byType(CropScreen))).pop(_rightHalf);
        await t.pumpAndSettle();
        final layout = _peek(t).layout;
        if (free) {
          final item = layout.items.singleWhere((i) => i.img == 0);
          expect(item.crop, _rightHalf);
          expect(item.rect.center.dx, closeTo(before.center.dx, 1e-9));
          expect(item.rect.center.dy, closeTo(before.center.dy, 1e-9));
          expect(item.rect.width / item.rect.height, closeTo(1, 1e-9));
          expect(layout.items.singleWhere((i) => i.img == 1).rect, neighbor);
        } else {
          expect(layout.fits[0].crop, _rightHalf);
          expect(layout.fits[1].crop, kCollageFullCrop);
        }
        expect(File(path).readAsBytesSync(), original);
        await t.tap(cropButton);
        await _wait(t, () => find.byType(CropScreen).evaluate().isNotEmpty);
        final cropScreen = t.widget<CropScreen>(find.byType(CropScreen));
        expect(cropScreen.initial, _rightHalf);
        await t.runAsync(() async {
          final codec = await ui.instantiateImageCodec(cropScreen.bytes);
          final frame = await codec.getNextFrame();
          expect(
            frame.image.width,
            80,
            reason: 'Recropping must show the full original',
          );
          expect(await _pixel(frame.image, 5, 20), Colors.red.toARGB32());
          frame.image.dispose();
          codec.dispose();
        });
        await t.pump();
        await t.tap(find.text('完成'));
        await t.pumpAndSettle();
        // Applying the existing rectangle and cancelling a later edit both keep it.
        await t.tap(cropButton);
        await _wait(t, () => find.byType(CropScreen).evaluate().isNotEmpty);
        Navigator.of(t.element(find.byType(CropScreen))).pop();
        await t.pumpAndSettle();
        expect(
          free
              ? _peek(t).layout.items.singleWhere((i) => i.img == 0).crop
              : _peek(t).layout.fits[0].crop,
          _rightHalf,
        );
        unawaited(t.state<NavigatorState>(find.byType(Navigator)).maybePop());
        await t.pumpAndSettle();
        await t.tap(find.text('保留草稿'));
        await _wait(t, () => find.byType(CollageScreen).evaluate().isEmpty);
        final raw = (await SharedPreferences.getInstance()).getString(
          kCollageDraftKey,
        )!;
        final draft = jsonDecode(raw) as Map<String, dynamic>;
        final rows = draft[free ? 'freeItems' : 'fits'] as List;
        final row = free ? rows.singleWhere((e) => e['img'] == 0) : rows[0];
        expect(row['crop'], [0.5, 0.0, 0.5, 1.0]);
        await t.pumpWidget(const SizedBox());
        await _open(t, draft);
        expect(
          free
              ? _peek(t).layout.items.singleWhere((i) => i.img == 0).crop
              : _peek(t).layout.fits[0].crop,
          _rightHalf,
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
      },
    );
  }
}
