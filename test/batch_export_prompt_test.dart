import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/services/video_processor.dart';
import 'package:markcut/widgets/batch_export_dialog.dart';

import 'editor_harness.dart' show mockEditorPlugins;

Future<Uint8List> _png() async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawColor(const Color(0xFF204060), BlendMode.src);
  final picture = rec.endRecording();
  final img = await picture.toImage(64, 64);
  picture.dispose();
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

Future<void> _pumpBatch(WidgetTester t, List<XFile> files) async {
  mockEditorPlugins(t.binding);
  SharedPreferences.setMockInitialValues({});
  await t.pumpWidget(MaterialApp(home: BatchWatermarkScreen(files: files)));
  for (var i = 0; i < 10; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  // 純影片、純照片與混合批次都只問一次；先選品質，確認後才開始。
  for (final kinds in [
    [false, false],
    [true, true],
    [false, true],
  ]) {
    testWidgets('批次 $kinds：匯出先選品質，取消不會匯出', (t) async {
      late Uint8List photo;
      await t.runAsync(() async => photo = await _png());
      await _pumpBatch(t, [
        for (var i = 0; i < kinds.length; i++)
          kinds[i]
              ? XFile.fromData(
                  Uint8List(32),
                  name: 'v$i.mp4',
                  mimeType: 'video/mp4',
                )
              : XFile.fromData(photo, name: 'p$i.png', mimeType: 'image/png'),
      ]);

      await t.tap(find.text('匯出'));
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('批次匯出設定'), findsOneWidget);
      expect(find.text('批次匯出中…'), findsNothing);
      expect(find.text('開始匯出'), findsOneWidget);
      expect(
        find.text('影片畫質'),
        kinds.contains(true) ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('JPEG'),
        kinds.contains(false) ? findsOneWidget : findsNothing,
      );
      if (kinds.contains(true)) {
        await t.tap(find.byKey(const ValueKey('batch-video-quality')));
        await t.pumpAndSettle();
        await t.tap(find.text('高畫質').last);
        await t.pumpAndSettle();
        expect(find.text('批次匯出中…'), findsNothing, reason: '選畫質不能直接啟動');
      }
      await t.tapAt(const Offset(4, 4));
      await t.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('批次匯出中…'), findsNothing);
      await t.tap(find.text('匯出'));
      await t.pumpAndSettle();
      expect(find.text('批次匯出設定'), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('混合批次確認會傳回實際選擇的影片與照片品質', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    BatchExportOptions? result;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<BatchExportOptions>(
                  context: context,
                  builder: (_) => const BatchExportDialog(
                    hasPhoto: true,
                    hasVideo: true,
                    initial: BatchExportOptions(),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('batch-video-quality')));
    await t.pumpAndSettle();
    await t.tap(find.text('省空間').last);
    await t.pumpAndSettle();
    final slider = find.byKey(const ValueKey('batch-photo-quality'));
    await t.tapAt(t.getCenter(slider));
    await t.pumpAndSettle();
    expect(find.text('照片品質 80%'), findsOneWidget);
    await t.tap(find.text('開始匯出'));
    await t.pumpAndSettle();
    expect(result!.videoQuality, ExportQuality.low);
    expect(result!.photoQuality, 80);
    expect(result!.jpeg, isTrue);
    expect(t.takeException(), isNull);
  });
}
