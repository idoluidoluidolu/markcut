import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/draft_assets.dart';
import 'package:markcut/services/timeline_thumbnail_cache.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/widgets/timeline_editor.dart';
import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'opening a draft restores its strip even when native frame decoding returns nothing',
    (t) async {
      late Directory root;
      late File source;
      final frame = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEMLQkAXrdVAdmuFfUAAAAASUVORK5CYII=',
      );
      SharedPreferences.setMockInitialValues({});
      Diag.reset();
      Diag.playerLayer.value = false;
      await t.runAsync(() async {
        root = await Directory.systemTemp.createTemp('draft-strip-');
        source = await File('${root.path}/source.mov').writeAsBytes([1, 2, 3]);
        BlobStore.dirOverride = root;
        WorkFiles.supportDirOverride = root;
        DraftAssets.supportDirOverride = root;
        WorkFiles.resetForTest();
        WorkFiles.holdSweep = true;
        await TimelineThumbnailCache.write(
          source.path,
          2,
          List.filled(10, frame),
        );
      });
      mockEditorPlugins(binding, tempDir: root);
      for (final name in ['markcut/comp', 'markcut/prep', 'markcut/frames']) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(name),
          (call) async {
            if (call.method == 'available') return name == 'markcut/comp';
            if (call.method == 'build') {
              return {
                'textureId': 1,
                'duration': 2.0,
                'width': 320.0,
                'height': 240.0,
                'ci': false,
              };
            }
            return null;
          },
        );
      }
      t.view.physicalSize = const Size(1100, 2200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        editorApp(
          VideoEditorScreen(
            draft: {
              'sources': [
                MediaSource(
                  path: source.path,
                  name: 'v',
                  kind: ClipKind.video,
                  duration: 2,
                  w: 320,
                  h: 240,
                ).toJson(),
              ],
              'clips': [
                TimelineClip(
                  id: 1,
                  sourceIndex: 0,
                  trimStart: 0,
                  trimEnd: 2,
                  offset: 0,
                  track: 0,
                ).toJson(),
              ],
            },
          ),
        ),
      );
      await settle(t);
      final timeline = t.widget<TimelineEditor>(find.byType(TimelineEditor));
      expect(timeline.thumbs[0], List.filled(10, frame));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await settle(t);
      await t.runAsync(() async {
        await TimelineThumbnailCache.clear();
        BlobStore.dirOverride = null;
        BlobStore.resetForTest();
        WorkFiles.supportDirOverride = null;
        WorkFiles.holdSweep = false;
        WorkFiles.resetForTest();
        DraftAssets.supportDirOverride = null;
        await root.delete(recursive: true);
      });
    },
  );
}
