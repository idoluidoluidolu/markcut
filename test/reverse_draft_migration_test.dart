import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/draft_assets.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/widgets/timeline_editor.dart';

import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File legacy;
  late String original;
  final channels = [
    'markcut/comp',
    'markcut/prep',
    'markcut/export',
    'markcut/frames',
    'com.llfbandit.record/messages',
    'plugins.flutter.io/path_provider',
    'dev.fluttercommunity.plus/wakelock',
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Diag.reset();
    Diag.playerLayer.value = false;
    root = await Directory.systemTemp.createTemp('reverse_migration_');
    legacy = await File('${root.path}/legacy.mp4').writeAsString('old reverse');
    original = '${root.path}/original.mov';
    WorkFiles.supportDirOverride = root;
    WorkFiles.resetForTest();
    WorkFiles.holdSweep = true;
    DraftAssets.supportDirOverride = root;
    mockEditorPlugins(binding, tempDir: root);
    for (final name in channels) {
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
          if (call.method == 'position') return 0;
          if (call.method == 'setClipVolumes') return true;
          if (name == 'plugins.flutter.io/path_provider') return root.path;
          return null;
        },
      );
    }
  });

  tearDown(() async {
    for (final name in channels) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      );
    }
    binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.arthenica.com/ffmpeg_kit'),
      null,
    );
    WorkFiles.supportDirOverride = null;
    WorkFiles.holdSweep = false;
    WorkFiles.resetForTest();
    DraftAssets.supportDirOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester t) async {
    for (var i = 0; i < 20; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 40));
    }
  }

  Future<TimelineModel> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final source = MediaSource(
      path: legacy.path,
      name: '倒轉素材',
      kind: ClipKind.video,
      duration: 2,
      w: 320,
      h: 240,
      revOf: original,
      revStart: 0,
      revEnd: 2,
      workPath: '${root.path}/obsolete-proxy.mp4',
    );
    final clip = TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 2,
      offset: 0,
      track: 0,
    );
    await t.pumpWidget(
      MaterialApp(
        home: VideoEditorScreen(
          draft: {
            'sources': [source.toJson()..remove('revColorVersion')],
            'clips': [clip.toJson()],
          },
        ),
      ),
    );
    await settleIo(t);
    expect(t.takeException(), isNull);
    return t.widget<TimelineEditor>(find.byType(TimelineEditor)).timeline;
  }

  testWidgets('舊倒轉檔仍存在也改用目前版本，並清除舊代理', (t) async {
    late String current;
    await t.runAsync(() async {
      await File(original).writeAsString('original');
      current = await WorkFiles.beginReverse(ext: 'mp4');
      await File(current).writeAsString('current reverse');
      await WorkFiles.commitReverse(original, 0, 2, current);
    });
    final timeline = await open(t);
    expect(timeline.clips, hasLength(1));
    expect(timeline.sources.first.path, current);
    expect(
      timeline.sources.first.revColorVersion,
      WorkFiles.reverseColorVersion,
    );
    expect(
      timeline.sources.first.workPath,
      isNot(endsWith('obsolete-proxy.mp4')),
    );
    await t.pumpWidget(const SizedBox());
    await settleIo(t);
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('原檔不存在不能更新時，保留舊倒轉片段並提示', (t) async {
    final timeline = await open(t);
    expect(timeline.clips, hasLength(1));
    expect(timeline.sources.first.path, legacy.path);
    expect(timeline.sources.first.revColorVersion, 0);
    expect(find.text('部分倒轉素材無法更新色彩，已保留原有檔案'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await settleIo(t);
    await t.pump(const Duration(seconds: 3));
  });
}
