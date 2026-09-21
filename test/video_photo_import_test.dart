import 'dart:async';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/crop_screen.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';

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

Future<void> tick(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  for (final outcome in [
    'cancel',
    'picker-error',
    'decode-error',
    'original',
    'crop',
  ]) {
    testWidgets('video editor photo import: $outcome', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      t.view.physicalSize = const Size(1100, 2200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      Diag.playerLayer.value = false;
      final picker = _Picker();
      FilePicker.platform = picker;
      final events = <String>[];
      final photoCalls = <MethodCall>[];
      final pauseAck = Completer<void>();
      var gatePause = false;
      for (final channel in [
        'com.llfbandit.record/messages',
        'plugins.flutter.io/path_provider',
        'dev.fluttercommunity.plus/wakelock',
        'markcut/frames',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => null,
        );
      }
      messenger.setMockMethodCallHandler(const MethodChannel('markcut/prep'), (
        call,
      ) async {
        if (call.method == 'setInteractive') {
          final args = call.arguments as Map;
          final paused = args['pauseDecoding'] == true;
          events.add('pause:$paused');
          if (gatePause && paused) await pauseAck.future;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(const MethodChannel('markcut/comp'), (
        call,
      ) async {
        if (call.method == 'available') return true;
        if (call.method == 'build') {
          return {
            'textureId': 1,
            'duration': 10.0,
            'width': 1080.0,
            'height': 1920.0,
          };
        }
        return null;
      });
      final png = (await t.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(12, 16);
        picture.dispose();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        image.dispose();
        return bytes;
      }))!;
      messenger.setMockMethodCallHandler(const MethodChannel('markcut/photo'), (
        call,
      ) async {
        photoCalls.add(call);
        if (call.method == 'imageWork') {
          events.add('${call.arguments}');
          return null;
        }
        if (call.method == 'preview') {
          if (outcome == 'decode-error') {
            throw PlatformException(code: 'invalid-photo');
          }
          final cropped = (call.arguments as Map)['path'] == '/crop.heic';
          return {'w': 6048, 'h': cropped ? 6048 : 8064, 'bytes': png};
        }
        if (call.method == 'crop') return '/crop.heic';
        return null;
      });
      await t.pumpWidget(
        const MaterialApp(home: VideoEditorScreen(blank: true)),
      );
      await tick(t);
      // Exercise the actual add-material menu and asynchronous picker lifecycle.
      t.widget<TimelineEditor>(find.byType(TimelineEditor)).onAddMedia(0);
      await tick(t);
      gatePause = true;
      await t.tap(find.text('圖片').last);
      await tick(t);
      expect(
        picker.calls,
        0,
        reason: 'native pause must be acknowledged before picker opens',
      );
      pauseAck.complete();
      await tick(t);
      expect(picker.calls, 1);
      expect(events, contains('begin'));
      expect(events.indexOf('pause:true'), lessThan(events.indexOf('begin')));
      if (outcome == 'cancel') {
        picker.result.complete(null);
      } else if (outcome == 'picker-error') {
        picker.result.completeError(StateError('picker failed'));
      } else {
        // This path does not exist: reading the original into Dart would fail.
        picker.result.complete(
          FilePickerResult([
            PlatformFile(
              name: 'camera.heic',
              path: '/camera-original.heic',
              size: 9000000,
            ),
          ]),
        );
      }
      await tick(t);
      if (outcome == 'original' || outcome == 'crop') {
        for (var i = 0; i < 10; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tick(t, 1);
        }
        expect(find.byType(CropScreen), findsOneWidget);
        if (outcome == 'crop') {
          await t.tap(find.text('1:1'));
          await tick(t);
        }
        await t.tap(find.text('完成'));
        await tick(t, 30);
        MediaSource? added;
        VideoEditorScreen.debugTimeline!((tl) {
          added = tl.sources.single;
        });
        expect(
          added!.path,
          outcome == 'original' ? '/camera-original.heic' : '/crop.heic',
        );
        expect(added!.w, 6048);
        expect(added!.h, outcome == 'original' ? 8064 : 6048);
        expect(
          photoCalls.where((c) => c.method == 'crop').length,
          outcome == 'original' ? 0 : 1,
        );
        expect(
          photoCalls
              .where((c) => c.method == 'preview')
              .every((c) => (c.arguments as Map)['maxSide'] == 2048),
          isTrue,
        );
      } else {
        expect(find.byType(CropScreen), findsNothing);
        VideoEditorScreen.debugTimeline!((tl) => expect(tl.sources, isEmpty));
      }
      await tick(t, 70);
      expect(events, contains('finish'));
      expect(events.last, 'pause:false');
      await t.pumpWidget(const SizedBox());
      await tick(t);
      expect(t.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
