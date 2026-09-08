import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/screens/collage_screen.dart';

class Picker extends FilePicker {
  String? path;
  int calls = 0;
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
  }) async {
    calls++;
    return path == null
        ? null
        : FilePickerResult([
            PlatformFile(name: 'photo.png', size: 1, path: path),
          ]);
  }
}

void main() {
  testWidgets('empty collage cells open picker and display selected photo', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final picker = Picker();
    FilePicker.platform = picker;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    late Directory dir;
    await t.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('collage-regression');
      final rec = ui.PictureRecorder();
      Canvas(rec).drawColor(Colors.red, BlendMode.src);
      final image = await rec.endRecording().toImage(120, 120);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picker.path = '${dir.path}/photo.png';
      await File(picker.path!).writeAsBytes(bytes!.buffer.asUint8List());
    });
    addTearDown(() => dir.delete(recursive: true));
    await t.pumpWidget(const MaterialApp(home: CollageScreen()));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      await t.tap(find.byIcon(Icons.add).first);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await t.pumpAndSettle();
    expect(picker.calls, 1);
    final state = t.state(find.byType(CollageScreen)) as CollageLayoutPeek;
    expect(state.images.whereType<ui.Image>().length, 1);
    expect(t.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
