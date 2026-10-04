import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/widgets/watermark_layer.dart';

import 'editor_harness.dart';

Finder get _drawnFrames => find.descendant(
  of: find.byType(WmFrameOverlay),
  matching: find.byType(DecoratedBox),
);

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final part in [WmPart.text, WmPart.logo]) {
    testWidgets('隱藏已選取的 ${part.name}：內容與框一起消失，重新顯示可恢復', (t) async {
      final settings = WatermarkSettings();
      settings.logo
        ..enabled = true
        ..bytesValue = solidPng(255, 0, 0);
      await t.pumpWidget(
        editorApp(VideoEditorScreen(blank: true, initialWatermark: settings)),
      );
      await settle(t, 5);
      t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).onSelectPart!(part);
      await settle(t, 3);
      expect(_drawnFrames, findsOneWidget);
      expect(editorOf(t).wmSelected, isTrue);

      editorOf(t).onToggleWmVisible!();
      await t.pump();
      expect(find.byType(WatermarkLayer), findsNothing);
      expect(_drawnFrames, findsNothing, reason: '隱藏當下不能殘留舊的選取框');
      expect(editorOf(t).wmSelected, isTrue, reason: '隱藏不必清掉時間軸選取');
      await settle(t, 3);
      expect(_drawnFrames, findsNothing);

      editorOf(t).onToggleWmVisible!();
      await settle(t, 3);
      expect(find.byType(WatermarkLayer), findsOneWidget);
      expect(_drawnFrames, findsOneWidget);
      expect(
        t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).selectedPart,
        part,
      );
      await t.pumpWidget(const SizedBox());
      await settle(t, 3);
    });
  }

  testWidgets('播放頭離開浮水印範圍時收起框，回到範圍內恢復', (t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await settle(t, 5);
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(path: '', name: '背景文字', kind: ClipKind.text, duration: 10),
      );
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 10,
          offset: 0,
          track: 0,
        ),
      );
    });
    await settle(t, 3);
    editorOf(t).onTrimWm(-6, false);
    editorOf(t).onWmGestureEnd?.call();
    await settle(t, 3);
    expect(_drawnFrames, findsOneWidget);

    editorOf(t).onSeek(6);
    await tick(t, 3);
    expect(find.byType(WatermarkLayer), findsNothing);
    expect(_drawnFrames, findsNothing);

    editorOf(t).onSeek(2);
    await tick(t, 3);
    expect(find.byType(WatermarkLayer), findsOneWidget);
    expect(_drawnFrames, findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await settle(t, 3);
  });
}
