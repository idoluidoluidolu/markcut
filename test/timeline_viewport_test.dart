import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/timeline_viewport.dart';
import 'package:markcut/widgets/timeline_editor.dart';

TimelineClip clip(int id, double start, double length, [int track = 0]) =>
    TimelineClip(
      id: id,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: length,
      offset: start,
      track: track,
    );

void main() {
  testWidgets(
    'one hour clip creates only visible thumbnail tiles, including its tail',
    (t) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
      final picture = recorder.endRecording();
      final bytes = await t.runAsync(() async {
        final image = await picture.toImage(4, 4);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return data!.buffer.asUint8List();
      });
      final model = TimelineModel();
      model.sources.add(
        MediaSource(
          path: '',
          name: 'long',
          kind: ClipKind.video,
          duration: 3600,
        ),
      );
      model.clips.add(clip(0, 0, 3600));
      final scroll = ScrollController();
      final playhead = ValueNotifier(0.0);
      addTearDown(() {
        scroll.dispose();
        playhead.dispose();
      });
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimelineEditor(
              timeline: model,
              thumbs: {
                0: [bytes!],
              },
              selectedId: -1,
              playhead: playhead,
              pxPerSec: 40,
              scrollController: scroll,
              onSelect: (_) {},
              onSeek: (_) {},
              onTrim: (_, _, _) {},
              onDrop: (_, _, _, _) {},
              onAddMedia: (_) {},
              onReorderTrack: (_, _) {},
              onToggleMute: (_) {},
              onLongPressClip: (_, _) {},
              onLongPressEmpty: (_, _, _) {},
              onSelectWm: () {},
              onMoveWm: (_) {},
              onTrimWm: (_, _) {},
            ),
          ),
        ),
      );
      await t.pump();
      final initial = find.byType(Image).evaluate().length;
      expect(initial, inInclusiveRange(1, 60));
      scroll.jumpTo(scroll.position.maxScrollExtent - 500);
      await t.pump();
      expect(find.byType(Image).evaluate().length, inInclusiveRange(1, 60));
      final tiles = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('tile'),
      );
      final indexes = tiles.evaluate().map(
        (e) =>
            int.parse((e.widget.key! as ValueKey<String>).value.substring(4)),
      );
      expect(
        indexes.first,
        greaterThan(400),
        reason: 'Do not truncate the filmstrip at tile 400',
      );
      // ignore: avoid_print
      print(
        'one hour clip: thumbnail widgets=$initial, at tail=${find.byType(Image).evaluate().length}',
      );
      await t.pumpWidget(const SizedBox());
    },
  );
  test(
    'viewport includes long overlaps, edges and pinned clips without duplicates',
    () {
      final clips = [
        clip(1, 0, 1000),
        clip(2, 5, 1),
        clip(3, 90, 10),
        clip(4, 110, 1),
        clip(5, 200, 1),
        clip(6, 100, 1, 1),
      ];
      final index = TimelineViewportIndex(clips.reversed);
      expect(index.visible(0, 100, 110, {1, 5, 6}).map((c) => c.id), [
        1,
        3,
        4,
        5,
      ]);
      expect(index.visible(4, 0, 100, {}).isEmpty, isTrue);
      expect(index.usedTracks, 2);
      expect(index.duration, 1000);
      expect(clips.map((c) => c.id), [1, 2, 3, 4, 5, 6]);
    },
  );

  test('large timeline query returns only nearby clips', () {
    final index = TimelineViewportIndex(
      List.generate(10000, (i) => clip(i, i * 2, 1)),
    );
    expect(index.visible(0, 15000, 15010, {}).map((c) => c.id), [
      7500,
      7501,
      7502,
      7503,
      7504,
      7505,
    ]);
  });

  testWidgets(
    '2000 clips stay bounded while scrolling both axes and retain selection',
    (t) async {
      final model = TimelineModel();
      model.sources.add(
        MediaSource(
          path: '',
          name: 'test',
          kind: ClipKind.video,
          duration: 3000,
        ),
      );
      model.clips.addAll(
        List.generate(2000, (i) => clip(i, (i % 100) * 20, 10, i ~/ 100)),
      );
      final horizontal = ScrollController();
      final vertical = ScrollController();
      final playhead = ValueNotifier(0.0);
      addTearDown(() {
        horizontal.dispose();
        vertical.dispose();
        playhead.dispose();
      });
      Widget host(int selected) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 260,
            child: SingleChildScrollView(
              controller: vertical,
              child: TimelineEditor(
                timeline: model,
                contentVersion: 1,
                viewportHeight: 260,
                verticalScrollController: vertical,
                thumbs: const {},
                selectedId: selected,
                playhead: playhead,
                pxPerSec: 20,
                scrollController: horizontal,
                onSelect: (_) {},
                onSeek: (_) {},
                onTrim: (_, _, _) {},
                onDrop: (_, _, _, _) {},
                onAddMedia: (_) {},
                onReorderTrack: (_, _) {},
                onToggleMute: (_) {},
                onLongPressClip: (_, _) {},
                onLongPressEmpty: (_, _, _) {},
                onSelectWm: () {},
                onMoveWm: (_) {},
                onTrimWm: (_, _) {},
              ),
            ),
          ),
        ),
      );
      int mountedClips() => find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('clip') &&
                RegExp(
                  r'^clip\d+$',
                ).hasMatch((w.key! as ValueKey<String>).value),
          )
          .evaluate()
          .length;
      await t.pumpWidget(host(-1));
      await t.pump();
      final initial = mountedClips();
      expect(initial, inInclusiveRange(1, 80));
      expect(find.byKey(const ValueKey('clip1900')), findsOneWidget);
      expect(find.byKey(const ValueKey('clip0')), findsNothing);
      horizontal.jumpTo(20000);
      vertical.jumpTo(vertical.position.maxScrollExtent);
      await t.pump();
      expect(mountedClips(), inInclusiveRange(1, 80));
      expect(find.byKey(const ValueKey('clip50')), findsOneWidget);
      expect(find.byKey(const ValueKey('clip1900')), findsNothing);
      await t.pumpWidget(host(1900));
      await t.pump();
      expect(
        find.byKey(const ValueKey('clip1900')),
        findsOneWidget,
        reason:
            'Selected clip and its track survive virtualization for gesture state',
      );
      // ignore: avoid_print
      print(
        '2000 clips: mounted at start=$initial, after scroll+pin=${mountedClips()}',
      );
      await t.pumpWidget(const SizedBox());
    },
  );
}
