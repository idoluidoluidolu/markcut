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
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/services/app_media_paths.dart';
import 'package:markcut/widgets/timeline_editor.dart';
import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'relocated HDR work index rescues a missing original without dropping clips',
    (t) async {
      final root = Directory.systemTemp.createTempSync('rescue-draft-');
      const old = '/private/var/mobile/Containers/Data/Application/OLD';
      final backup = File(
        '${root.path}${Platform.pathSeparator}Library${Platform.pathSeparator}Application Support${Platform.pathSeparator}workfiles${Platform.pathSeparator}hdr.mov',
      );
      backup.parent.createSync(recursive: true);
      backup.writeAsStringSync('hdr backup');
      AppMediaPaths.setRootForTest(root.path);
      BlobStore.resetForTest();
      WorkFiles.resetForTest();
      WorkFiles.supportDirOverride = backup.parent.parent;
      SharedPreferences.setMockInitialValues({
        'workFiles.v4': jsonEncode({
          '$old/tmp/original.mov#hdr6': {
            'work': '$old/Library/Application Support/workfiles/hdr.mov',
            'stamp': 'old-stamp',
            'at': 1,
          },
        }),
      });
      Diag.reset();
      Diag.playerLayer.value = false;
      mockEditorPlugins(binding, tempDir: backup.parent.parent);
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
      final draft = {
        'sources': [
          MediaSource(
            path: '$old/tmp/original.mov',
            name: 'original',
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
      };
      await BlobStore.write('project_data_rescue', jsonEncode(draft));
      t.view.physicalSize = const Size(1100, 2200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        editorApp(VideoEditorScreen(draftId: 'rescue', draft: draft)),
      );
      await waitUntil(
        t,
        () => find.byType(TimelineEditor).evaluate().isNotEmpty,
      );
      final model = modelOf(t);
      expect(model.clips, hasLength(1));
      final rescued = model.sources.single;
      expect(
        rescued.path,
        contains('${Platform.pathSeparator}imports${Platform.pathSeparator}'),
      );
      expect(rescued.workHdrPath, rescued.path);
      expect(File(rescued.path).readAsStringSync(), 'hdr backup');
      expect(
        backup.existsSync(),
        isTrue,
        reason: 'The previous backup must survive the handoff',
      );
      await settle(t);
      final saved = await DraftStore.load('rescue');
      expect((saved!['sources'] as List).single['path'], rescued.path);
      await t.pumpWidget(const SizedBox());
      await settle(t);
      expect(t.takeException(), isNull);
      DraftStore.releaseOpen('rescue');
      AppMediaPaths.setRootForTest(null);
      WorkFiles.supportDirOverride = null;
      WorkFiles.resetForTest();
      await t.runAsync(() => root.delete(recursive: true));
    },
  );

  for (final kind in [ClipKind.video, ClipKind.image, ClipKind.audio]) {
    testWidgets(
      'unavailable $kind preserves original draft through load and exit',
      (t) async {
        final root = Directory.systemTemp.createTempSync('missing-draft-');
        SharedPreferences.setMockInitialValues({});
        BlobStore.resetForTest();
        WorkFiles.resetForTest();
        WorkFiles.supportDirOverride = root;
        Diag.reset();
        Diag.playerLayer.value = false;
        mockEditorPlugins(binding, tempDir: root);
        for (final channel in [
          'markcut/comp',
          'markcut/prep',
          'markcut/frames',
        ]) {
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            MethodChannel(channel),
            (_) async => null,
          );
        }
        final draft = {
          'sources': [
            MediaSource(
              path: '${root.path}/missing.mov',
              name: 'keep me',
              kind: kind,
              duration: 2,
            ).toJson(),
            MediaSource(
              path: '',
              name: 'caption',
              kind: ClipKind.text,
              duration: 2,
            ).toJson(),
          ],
          'clips': [
            for (var i = 0; i < 2; i++)
              TimelineClip(
                id: i + 1,
                sourceIndex: i,
                trimStart: 0,
                trimEnd: 2,
                offset: 0,
                track: i,
              ).toJson(),
          ],
        };
        final original = jsonEncode(draft);
        await BlobStore.write('project_data_missing', original);
        t.view.physicalSize = const Size(1100, 2200);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.resetPhysicalSize);
        addTearDown(t.view.resetDevicePixelRatio);
        await t.pumpWidget(
          editorApp(VideoEditorScreen(draftId: 'missing', draft: draft)),
        );
        await waitUntil(
          t,
          () => find.textContaining('原草稿已保留').evaluate().isNotEmpty,
        );
        expect(find.byType(TimelineEditor), findsNothing);
        VideoEditorScreen.debugTimeline!(
          (model) => expect(model.clips, hasLength(2)),
        );
        await t.pump(const Duration(seconds: 3));
        expect(await BlobStore.read('project_data_missing'), original);
        await t.pumpWidget(const SizedBox());
        await settle(t);
        expect(await BlobStore.read('project_data_missing'), original);
        expect(DraftStore.hasOpenDrafts, isFalse);
        expect(t.takeException(), isNull);
        WorkFiles.supportDirOverride = null;
        WorkFiles.resetForTest();
        await t.runAsync(() => root.delete(recursive: true));
      },
    );
  }
}
