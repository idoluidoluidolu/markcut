// 批次匯出的設定：跟影片編輯的匯出頁同一套（使用者指定「用我影片編輯
// 那個模板」）——一列一列「標籤　值 ›」，點了開置中的選單彈窗，最下面
// 一顆匯出鈕。按匯出才開始；關掉＝不匯出
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/services/video_processor.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/batch_export_sheet.dart';

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

/// 匯出設定那一張裡的字
Finder _inSheet(String text) => find.descendant(
  of: find.byType(BatchExportSheet),
  matching: find.text(text),
);

void main() {
  // 純影片、純照片與混合批次都只問一次；先選品質，按了匯出才開始
  for (final kinds in [
    [false, false],
    [true, true],
    [false, true],
  ]) {
    testWidgets('批次 $kinds：匯出先跳設定（影片編輯那一套），關掉不會匯出', (t) async {
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
      final videos = kinds.where((v) => v).length;
      final photos = kinds.length - videos;

      await t.tap(find.text('匯出'));
      await t.pumpAndSettle();
      expect(find.byType(BatchExportSheet), findsOneWidget);
      expect(find.text('批次匯出中…'), findsNothing);
      // 影片編輯那一套：一列一列「標籤　值 ›」
      expect(_inSheet('畫質'), videos > 0 ? findsOneWidget : findsNothing);
      expect(_inSheet('照片格式'), photos > 0 ? findsOneWidget : findsNothing);
      expect(_inSheet('照片品質'), photos > 0 ? findsOneWidget : findsNothing);
      expect(
        _inSheet(
          [
            if (videos > 0) '影片 $videos 支',
            if (photos > 0) '照片 $photos 張',
          ].join('·'),
        ),
        findsOneWidget,
      );
      if (videos > 0) {
        // 點一列開置中的選單彈窗；選了就關掉、值換掉，不會直接開始匯出
        await t.tap(_inSheet('畫質'));
        await t.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await t.tap(find.text('最高畫質').last);
        await t.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(_inSheet('最高畫質'), findsOneWidget);
        expect(find.text('批次匯出中…'), findsNothing, reason: '選畫質不能直接啟動');
      }
      // 點外面關掉＝不匯出
      await t.tapAt(const Offset(4, 4));
      await t.pumpAndSettle();
      expect(find.byType(BatchExportSheet), findsNothing);
      expect(find.text('批次匯出中…'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('混合批次：按匯出傳回實際選的影片畫質、照片格式與品質', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    BatchExportOptions? result;
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showBatchExportSheet(
                  context,
                  photos: 3,
                  videos: 2,
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
    // 預設：影片自動、照片 JPEG 高畫質
    expect(_inSheet('自動·推薦'), findsOneWidget);
    expect(_inSheet('JPEG'), findsOneWidget);
    expect(_inSheet('高畫質'), findsOneWidget);

    await t.tap(_inSheet('畫質'));
    await t.pumpAndSettle();
    await t.tap(find.text('省空間').last);
    await t.pumpAndSettle();
    expect(_inSheet('省空間'), findsOneWidget);

    await t.tap(_inSheet('照片品質'));
    await t.pumpAndSettle();
    await t.tap(find.text('標準').last);
    await t.pumpAndSettle();
    expect(_inSheet('標準'), findsOneWidget);

    // PNG 是無損：沒有品質可以挑，那一列收起來；切回 JPEG 剛剛選的還在
    await t.tap(_inSheet('照片格式'));
    await t.pumpAndSettle();
    await t.tap(find.text('PNG 無損').last);
    await t.pumpAndSettle();
    expect(_inSheet('照片品質'), findsNothing);
    await t.tap(_inSheet('照片格式'));
    await t.pumpAndSettle();
    await t.tap(find.text('JPEG').last);
    await t.pumpAndSettle();
    expect(_inSheet('標準'), findsOneWidget);

    await t.tap(_inSheet('匯出'));
    await t.pumpAndSettle();
    expect(result!.videoQuality, ExportQuality.low);
    expect(result!.photoQuality, 85);
    expect(result!.jpeg, isTrue);
    expect(t.takeException(), isNull);
  });

  test('照片品質落在四檔之間時取最接近的那一檔', () {
    expect(photoQualityLevel(92).$2, '高畫質');
    expect(photoQualityLevel(80).$1, 75);
    expect(photoQualityLevel(97).$1, 100);
    expect(photoQualityLevel(60).$2, '省空間');
  });
}
