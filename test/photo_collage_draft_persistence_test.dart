import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/screens/crop_screen.dart';
import 'package:markcut/screens/photo_editor_screen.dart';
import 'package:markcut/services/draft_assets.dart';
import 'package:markcut/widgets/watermark_panel.dart';

class _Picker extends FilePicker {
  late String path;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([PlatformFile(name: 'source.png', size: 1, path: path)]);
}

class _RejectDraftStore extends InMemorySharedPreferencesStore {
  _RejectDraftStore(this.key, this.throwWrite) : super.empty();
  final String key;
  final bool throwWrite;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.${this.key}') {
      if (throwWrite) throw StateError('Disk write failed');
      return false;
    }
    return super.setValue(type, key, value);
  }
}

Future<Uint8List> _stripedPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.blue, BlendMode.src);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 30, 60),
    Paint()..color = Colors.red,
  );
  canvas.drawRect(
    const Rect.fromLTWH(90, 0, 30, 60),
    Paint()..color = Colors.green,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(120, 60);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> _settleIo(WidgetTester t, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 35)),
    );
    await t.pump(const Duration(milliseconds: 35));
  }
}

Future<void> _open(WidgetTester t, Widget page) async {
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => page),
              ),
              child: const Text('開啟編輯器'),
            ),
          );
        },
      ),
    ),
  );
  await t.tap(find.text('開啟編輯器'));
  await _settleIo(t);
}

Future<void> _keepDraft(WidgetTester t) async {
  await t.runAsync(() => t.pageBack());
  await t.pumpAndSettle();
  await t.runAsync(() async {
    await t.tap(find.text('保留草稿'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await _settleIo(t);
  await t.pumpAndSettle();
}

void main() {
  late Directory dir;
  late File source;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('draft_pixels_');
    final pickerDir = await Directory('${dir.path}/picker').create();
    source = File('${pickerDir.path}/source.png');
    DraftAssets.supportDirOverride = Directory('${dir.path}/support');
    DraftAssets.pickerRootsOverride = [pickerDir];
    FilePicker.platform = _Picker()..path = source.path;
  });
  tearDown(() async {
    DraftAssets.supportDirOverride = null;
    DraftAssets.pickerRootsOverride = null;
    DraftAssets.maxFileBytesOverride = null;
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });

  testWidgets('照片保留草稿使用持久原檔，暫存檔移除後仍可續作', (t) async {
    t.view.physicalSize = const Size(800, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async => source.writeAsBytes(await _stripedPng()));
    await _open(t, PhotoEditorScreen(photo: XFile(source.path)));
    t.widget<WatermarkPanel>(find.byType(WatermarkPanel)).settings.text.text =
        '持久草稿';
    await _keepDraft(t);
    expect(find.byType(PhotoEditorScreen), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    final draft =
        jsonDecode(prefs.getString(kPhotoDraftKey)!) as Map<String, dynamic>;
    final keptPath = draft['photo'] as String;
    expect(keptPath, isNot(source.path));
    expect(keptPath, contains('draft_assets'));
    await t.runAsync(() async {
      if (await source.exists()) await source.delete();
      expect(await File(keptPath).exists(), isTrue);
    });
    await _open(
      t,
      PhotoEditorScreen(
        photo: XFile(keptPath),
        draft: draft['state'] as String,
      ),
    );
    expect(find.byType(PhotoEditorScreen), findsOneWidget);
    expect(
      t.widget<WatermarkPanel>(find.byType(WatermarkPanel)).settings.text.text,
      '持久草稿',
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is RawImage && w.image?.width == 120 && w.image?.height == 60,
      ),
      findsWidgets,
    );
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await _settleIo(t);
  });

  testWidgets('照片草稿複本保存失敗時留在編輯器，不假裝已保留', (t) async {
    t.view.physicalSize = const Size(800, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.runAsync(() async => source.writeAsBytes(await _stripedPng()));
    DraftAssets.maxFileBytesOverride = 1;
    await _open(t, PhotoEditorScreen(photo: XFile(source.path)));
    t.widget<WatermarkPanel>(find.byType(WatermarkPanel)).settings.text.text =
        '不可遺失';
    await _keepDraft(t);
    expect(find.byType(PhotoEditorScreen), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kPhotoDraftKey), isNull);
    expect(find.textContaining('草稿保存失敗'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await _settleIo(t);
    await t.pump(const Duration(seconds: 4));
    expect(t.takeException(), isNull);
  });

  testWidgets('拼圖換圖裁切後保留草稿，續作像素與裁切尺寸不變', (t) async {
    t.view.physicalSize = const Size(800, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final picker = _Picker()..path = source.path;
    FilePicker.platform = picker;
    await t.runAsync(() async => source.writeAsBytes(await _stripedPng()));
    await _open(t, CollageScreen(photos: [XFile(source.path)]));
    final cell = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_CellPainter',
    );
    await t.tap(cell.first);
    await t.pump();
    await t.runAsync(() => t.tap(find.byIcon(Icons.cached)));
    await _settleIo(t);
    expect(find.byType(CropScreen), findsOneWidget);
    await t.pumpAndSettle();
    await t.tap(
      find.descendant(of: find.byType(CropScreen), matching: find.text('1:1')),
    );
    await t.pump();
    await t.runAsync(() => t.tap(find.text('完成')));
    await _settleIo(t);
    final before = t.state(find.byType(CollageScreen)) as CollageLayoutPeek;
    final cropped = before.images[before.layout.order.first]!;
    expect((cropped.width, cropped.height), (60, 60));
    late Uint8List expected;
    await t.runAsync(() async {
      expected = (await cropped.toByteData())!.buffer.asUint8List();
    });
    await _keepDraft(t);
    final prefs = await SharedPreferences.getInstance();
    final draft =
        jsonDecode(prefs.getString(kCollageDraftKey)!) as Map<String, dynamic>;
    final selected = (draft['order'] as List).first as int;
    expect((draft['photos'] as List)[selected], isNot(source.path));
    await t.runAsync(() async {
      if (await source.exists()) await source.delete();
    });
    await _open(t, CollageScreen(restore: draft));
    final after = t.state(find.byType(CollageScreen)) as CollageLayoutPeek;
    final restored = after.images[after.layout.order.first]!;
    expect((restored.width, restored.height), (60, 60));
    await t.runAsync(() async {
      expect((await restored.toByteData())!.buffer.asUint8List(), expected);
    });
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await _settleIo(t);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final (collage, throwWrite) in [
    (false, false),
    (true, false),
    (false, true),
    (true, true),
  ]) {
    testWidgets(
      '${collage ? '拼圖' : '照片'}草稿設定寫入${throwWrite ? '拋出錯誤' : '遭拒'}時留在編輯器且不留下假快取',
      (t) async {
        t.view.physicalSize = const Size(800, 1400);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final key = collage ? kCollageDraftKey : kPhotoDraftKey;
        final previous = SharedPreferencesStorePlatform.instance;
        final store = _RejectDraftStore(key, throwWrite);
        SharedPreferencesStorePlatform.instance = store;
        addTearDown(() {
          SharedPreferencesStorePlatform.instance = previous;
          SharedPreferences.resetStatic();
        });
        await t.runAsync(() async => source.writeAsBytes(await _stripedPng()));
        await _open(
          t,
          collage
              ? CollageScreen(photos: [XFile(source.path)])
              : PhotoEditorScreen(photo: XFile(source.path)),
        );
        if (!collage) {
          t
                  .widget<WatermarkPanel>(find.byType(WatermarkPanel))
                  .settings
                  .text
                  .text =
              '不要遺失';
        }
        await _keepDraft(t);
        expect(
          find.byType(collage ? CollageScreen : PhotoEditorScreen),
          findsOneWidget,
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(key), isNull);
        expect((await store.getAll())['flutter.$key'], isNull);
        expect(find.textContaining('草稿保存失敗'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
        await _settleIo(t);
        await t.pump(const Duration(seconds: 4));
        expect(t.takeException(), isNull);
      },
    );
  }
}
