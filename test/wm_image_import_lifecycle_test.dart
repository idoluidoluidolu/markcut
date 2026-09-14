import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/widgets/watermark_panel.dart';

class _Picker extends FilePicker {
  final result = Completer<FilePickerResult?>();
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
  }) {
    calls++;
    return result.future;
  }
}

void main() {
  for (final fail in [false, true]) {
    testWidgets(
      'image picker waits for pause and releases it on ${fail ? "error" : "cancel"}',
      (t) async {
        SharedPreferences.setMockInitialValues({});
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final picker = _Picker();
        FilePicker.platform = picker;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final acknowledged = Completer<void>();
        final activity = <bool>[];
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WatermarkPanel(
                settings: WatermarkSettings(),
                onChanged: () {},
                onImageWork: (active) async {
                  activity.add(active);
                  if (active) await acknowledged.future;
                },
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.text('圖片').first);
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('加入圖片'));
        await t.pump();
        expect(activity, [true]);
        expect(picker.calls, 0);
        acknowledged.complete();
        await t.pump();
        expect(picker.calls, 1);
        await t.tap(find.byTooltip('加入圖片'));
        await t.pump();
        expect(picker.calls, 1);
        if (fail) {
          picker.result.completeError(StateError('picker failed'));
        } else {
          picker.result.complete(null);
        }
        await t.pumpAndSettle();
        expect(activity, [true, false]);
        await t.pump(const Duration(seconds: 3)); // transient error hint
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
