import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/preview_preparation.dart';

TimelineModel stacked() {
  final timeline = TimelineModel();
  const durations = [48.0, 3.84, 1.2, 2.47, 5.67];
  for (var i = 0; i < durations.length; i++) {
    timeline.sources.add(
      MediaSource(
        path: '/$i.mov',
        name: '$i',
        kind: ClipKind.video,
        duration: durations[i],
        w: 2160,
        h: 3840,
      ),
    );
    timeline.clips.add(
      TimelineClip(
        id: i,
        sourceIndex: i,
        trimStart: 0,
        trimEnd: durations[i],
        offset: 0,
        track: i,
      ),
    );
  }
  return timeline;
}

void main() {
  test(
    'visible top video then short pending clips, without reordering edits',
    () {
      final tl = stacked();
      final sourceOrder = tl.sources.toList();
      final clipOrder = tl.clips.toList();
      final pending = [0, 1, 2, 3, 4];
      expect(
        prioritizePreviewPreparation(
          timeline: tl,
          pending: pending,
          position: 0,
        ),
        [4, 2, 3, 1, 0],
      );
      expect(tl.sources, sourceOrder);
      expect(tl.clips, clipOrder);
      expect(pending, [0, 1, 2, 3, 4]);
    },
  );

  test('next job follows changed playhead and hidden track state', () {
    final tl = stacked();
    expect(
      prioritizePreviewPreparation(
        timeline: tl,
        pending: [0, 1, 2, 3, 4],
        position: 6,
      ).first,
      0,
    );
    expect(
      prioritizePreviewPreparation(
        timeline: tl,
        pending: [0, 1, 2, 3, 4],
        position: 0,
        hiddenTracks: {4},
      ),
      [3, 2, 1, 0, 4],
    );
  });

  test('near upcoming clips beat remote jobs and invalid jobs are omitted', () {
    final tl = stacked();
    tl.clips[1].offset = 55;
    tl.clips[2].offset = 200;
    tl.clips[3].offset = 50;
    tl.sources.add(
      MediaSource(
        path: '/photo',
        name: 'photo',
        kind: ClipKind.image,
        duration: 1,
      ),
    );
    expect(
      prioritizePreviewPreparation(
        timeline: tl,
        pending: [2, -1, 100, 5, 1, 3, 3],
        position: 49,
      ),
      [3, 1, 2],
    );
  });

  testWidgets(
    'busy edge immediate; resume only after a continuous idle interval',
    (t) async {
      final events = <bool>[];
      final activity = PreviewPreparationActivity(onChanged: events.add);
      activity.update(true);
      activity.update(true);
      expect(events, [true]);
      activity.update(false);
      await t.pump(const Duration(milliseconds: 400));
      activity.update(true);
      await t.pump(const Duration(seconds: 1));
      expect(events, [true]);
      activity.update(false);
      await t.pump(const Duration(milliseconds: 300));
      activity.update(false);
      await t.pump(const Duration(milliseconds: 300));
      expect(events, [true, false]);
      activity.dispose();
    },
  );

  testWidgets(
    'dispose cancels timer and releases a paused native job exactly once',
    (t) async {
      final events = <bool>[];
      final activity = PreviewPreparationActivity(onChanged: events.add);
      activity.update(true);
      activity.update(false);
      activity.dispose();
      activity.update(true);
      await t.pump(const Duration(seconds: 5));
      activity.dispose();
      expect(events, [true, false]);
    },
  );
}
