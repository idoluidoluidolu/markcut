import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/widgets/timeline_editor.dart';

void main() {
  for (final before in [true, false]) {
    for (final snap in [true, false]) {
      testWidgets(
        'hint matches ${before ? "left" : "right"} insertion (snap $snap)',
        (t) async {
          final scene = await _pump(t, snap: snap);
          final moving = scene.tl.clips.first;
          final target = scene.tl.clips[1];
          final targetRect = t.getRect(
            find.byKey(ValueKey('clip${target.id}')),
          );
          final start = t.getCenter(find.byKey(ValueKey('clip${moving.id}')));
          final finger = await t.startGesture(start);
          await finger.moveBy(Offset((before ? 4 : 6) * 30, 0));
          await t.pump();
          expect(find.text(before ? '即將插入左側' : '即將插入右側'), findsOneWidget);
          final hint = t.getRect(
            find.byKey(const ValueKey('clip-insertion-hint')),
          );
          expect(
            hint.center.dx,
            closeTo(before ? targetRect.left : targetRect.right, .01),
          );
          expect(hint.top, closeTo(targetRect.top, .01));
          expect(scene.tl.clips.map((c) => c.offset), [
            0,
            3,
            7,
          ], reason: 'hover is read-only');
          await finger.up();
          await t.pumpAndSettle();
          expect(scene.drops, 1);
          expect(moving.offset, before ? 3 : 7);
          expect(target.offset, before ? 5 : 3);
          expect(scene.tl.firstOverlapOnTracks(), isNull);
          expect(
            find.byKey(const ValueKey('clip-insertion-hint')),
            findsNothing,
          );
          expect(t.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('right insertion label stays inside a phone viewport', (t) async {
    final scene = await _pump(t, width: 390);
    final finger = await t.startGesture(
      t.getCenter(find.byKey(ValueKey('clip${scene.tl.clips.first.id}'))),
    );
    await finger.moveBy(const Offset(180, 0));
    await t.pump();
    final label = t.getRect(find.text('即將插入右側'));
    expect(label.left, greaterThanOrEqualTo(0));
    expect(label.right, lessThanOrEqualTo(390));
    expect(t.takeException(), isNull);
    await finger.up();
    await t.pumpAndSettle();
    expect(scene.tl.clips.first.offset, 7);
  });

  testWidgets('pinch cancels an insertion hint without moving clips', (
    t,
  ) async {
    final scene = await _pump(t);
    final finger = await t.startGesture(
      t.getCenter(find.byKey(ValueKey('clip${scene.tl.clips.first.id}'))),
      pointer: 1,
    );
    await finger.moveBy(const Offset(120, 0));
    await t.pump();
    expect(find.text('即將插入左側'), findsOneWidget);
    final second = await t.startGesture(const Offset(600, 60), pointer: 2);
    await t.pump();
    expect(find.byKey(const ValueKey('clip-insertion-hint')), findsNothing);
    await second.up();
    await finger.up();
    await t.pumpAndSettle();
    expect(scene.drops, 0);
    expect(scene.tl.clips.map((c) => c.offset), [0, 3, 7]);
  });

  testWidgets('empty track and new layer show no horizontal insertion hint', (
    t,
  ) async {
    final scene = await _pump(t);
    final finger = await t.startGesture(
      t.getCenter(find.byKey(ValueKey('clip${scene.tl.clips.first.id}'))),
    );
    await finger.moveBy(const Offset(120, -28));
    await t.pump();
    expect(find.text('插入成新的一層'), findsOneWidget);
    expect(find.byKey(const ValueKey('clip-insertion-hint')), findsNothing);
    await finger.moveBy(const Offset(0, -34));
    await t.pump();
    expect(find.byKey(const ValueKey('clip-insertion-hint')), findsNothing);
    await finger.up();
    await t.pumpAndSettle();
    expect(scene.drops, 1);
    expect(scene.tl.clips.first.track, 1);
    expect(scene.tl.clips.first.offset, 4);
  });

  test(
    'style overlap and empty gaps are free placement; midpoint goes right',
    () {
      final tl = _Scene().tl;
      final moving = tl.clips.first;
      expect(tl.placementOnTrack(moving, 2.5, 0).targetId, isNull);
      expect(tl.placementOnTrack(moving, 4, 1).targetId, isNull);
      expect(tl.placementOnTrack(moving, 5, 0), (
        offset: 7.0,
        targetId: tl.clips[1].id,
        before: false,
      ));
      tl.sources.add(
        MediaSource(
          path: '',
          name: 'text',
          kind: ClipKind.text,
          w: 100,
          h: 100,
          duration: 10,
        ),
      );
      final style = TimelineClip(
        id: tl.nextId(),
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 2,
        offset: 0,
        track: 0,
      );
      expect(tl.placementOnTrack(style, 4, 0), (
        offset: 4.0,
        targetId: null,
        before: false,
      ));
    },
  );
}

class _Scene {
  final tl = TimelineModel();
  int drops = 0;
  _Scene() {
    tl.sources.add(
      MediaSource(
        path: 'v.mp4',
        name: 'v',
        kind: ClipKind.video,
        w: 1080,
        h: 1920,
        duration: 20,
      ),
    );
    for (final (offset, length) in [(0.0, 2.0), (3.0, 4.0), (7.0, 2.0)]) {
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: length,
          offset: offset,
          track: 0,
        ),
      );
    }
  }
}

Future<_Scene> _pump(
  WidgetTester t, {
  bool snap = false,
  double width = 1200,
}) async {
  t.view.physicalSize = Size(width, 700);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final scene = _Scene();
  final scroll = ScrollController();
  final playhead = ValueNotifier<double>(0);
  addTearDown(scroll.dispose);
  addTearDown(playhead.dispose);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: TimelineEditor(
            timeline: scene.tl,
            thumbs: <int, List<Uint8List>>{},
            selectedId: scene.tl.clips.first.id,
            playhead: playhead,
            pxPerSec: 30,
            trackScale: 1,
            scrollController: scroll,
            onSelect: (_) {},
            onSeek: (_) {},
            onTrim: (_, _, _) {},
            onDrop: (id, offset, track, insert) {
              scene.drops++;
              final c = scene.tl.clips.firstWhere((c) => c.id == id);
              c.offset = insert
                  ? offset
                  : scene.tl.placeOffsetOnTrack(c, offset, track);
              c.track = track;
              if (!insert) scene.tl.resolveOverlaps(track: track, pinnedId: id);
            },
            onAddMedia: (_) {},
            onReorderTrack: (_, _) {},
            mutedTracks: const {},
            onToggleMute: (_) {},
            onLongPressClip: (_, _) {},
            onLongPressEmpty: (_, _, _) {},
            onSelectWm: () {},
            onMoveWm: (_) {},
            onTrimWm: (_, _) {},
            selectedTrack: -1,
            snapEnabled: snap,
            extraTracks: 0,
            wmLabel: '',
            wmSelected: false,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return scene;
}
