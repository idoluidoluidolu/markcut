import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/thumbnail_preparation.dart';

void main() {
  test(
    'every clip gets a cover in priority order before a complete strip',
    () async {
      final events = <String>[];
      final counts = <String, int>{};
      await prepareTimelineThumbnails<String>(
        items: () => ['top', 'middle', 'base'],
        alive: () => true,
        canLoadCover: () => true,
        needsCover: (item) => (counts[item] ?? 0) == 0,
        needsStrip: (item) => (counts[item] ?? 0) < 10,
        waitForStrip: () async {
          events.add('idle');
        },
        load: (item, coverOnly) async {
          events.add('${coverOnly ? 'cover' : 'strip'}:$item');
          counts[item] = coverOnly ? 1 : 10;
        },
      );
      expect(events.take(3), ['cover:top', 'cover:middle', 'cover:base']);
      expect(events.skip(3), [
        'idle',
        'strip:top',
        'idle',
        'strip:middle',
        'idle',
        'strip:base',
      ]);
    },
  );

  test(
    'covers remain serial and new priority clips join before strips',
    () async {
      final firstCover = Completer<void>();
      final enteredFirst = Completer<void>();
      final counts = <String, int>{};
      final events = <String>[];
      var items = ['top', 'base'];
      var active = 0;
      var peak = 0;
      final run = prepareTimelineThumbnails<String>(
        items: () => items,
        alive: () => true,
        // A drag is intentionally not a blocker for a single small cover.
        canLoadCover: () => true,
        needsCover: (item) => (counts[item] ?? 0) == 0,
        needsStrip: (item) => (counts[item] ?? 0) < 10,
        waitForStrip: () async {},
        load: (item, coverOnly) async {
          active++;
          if (active > peak) peak = active;
          events.add('${coverOnly ? 'cover' : 'strip'}:$item');
          if (item == 'top' && coverOnly) {
            enteredFirst.complete();
            await firstCover.future;
          }
          counts[item] = coverOnly ? 1 : 10;
          active--;
        },
      );
      await enteredFirst.future;
      expect(events, ['cover:top']);
      items = ['newTop', 'top', 'base'];
      firstCover.complete();
      await run;
      expect(events.take(3), ['cover:top', 'cover:newTop', 'cover:base']);
      expect(peak, 1);
    },
  );

  test('playback blocks the next cover request until it stops', () async {
    final resume = Completer<void>();
    final waiting = Completer<void>();
    var playing = true;
    var count = 0;
    var loads = 0;
    final run = prepareTimelineThumbnails<int>(
      items: () => [0],
      alive: () => true,
      canLoadCover: () => !playing,
      needsCover: (_) => count == 0,
      needsStrip: (_) => false,
      waitForStrip: () async {},
      waitWhileBusy: () {
        waiting.complete();
        return resume.future;
      },
      load: (_, coverOnly) async {
        loads++;
        count = 1;
      },
    );
    await waiting.future;
    expect(loads, 0);
    playing = false;
    resume.complete();
    await run;
    expect(loads, 1);
  });

  test(
    'complete strips wait for idle and reconsider newly imported covers',
    () async {
      final idle = Completer<void>();
      final waiting = Completer<void>();
      var items = ['existing'];
      final counts = {'existing': 1};
      final events = <String>[];
      var waits = 0;
      final run = prepareTimelineThumbnails<String>(
        items: () => items,
        alive: () => true,
        canLoadCover: () => true,
        needsCover: (item) => (counts[item] ?? 0) == 0,
        needsStrip: (item) => (counts[item] ?? 0) < 10,
        waitForStrip: () async {
          if (waits++ == 0) {
            waiting.complete();
            await idle.future;
          }
        },
        load: (item, coverOnly) async {
          events.add('${coverOnly ? 'cover' : 'strip'}:$item');
          counts[item] = coverOnly ? 1 : 10;
        },
      );
      await waiting.future;
      expect(
        events,
        isEmpty,
        reason: 'No full strip starts while preview is busy.',
      );
      items = ['newTop', 'existing'];
      idle.complete();
      await run;
      expect(events, ['cover:newTop', 'strip:newTop', 'strip:existing']);
    },
  );

  test(
    'a failed cover is not retried forever and disposal stops waiting work',
    () async {
      var attempts = 0;
      await prepareTimelineThumbnails<int>(
        items: () => [0],
        alive: () => true,
        canLoadCover: () => true,
        needsCover: (_) => true,
        needsStrip: (_) => false,
        waitForStrip: () async {},
        load: (_, _) async {
          attempts++;
        },
      );
      expect(attempts, 1);

      var alive = true;
      await prepareTimelineThumbnails<int>(
        items: () => [0],
        alive: () => alive,
        canLoadCover: () => true,
        needsCover: (_) => false,
        needsStrip: (_) => true,
        waitForStrip: () async {
          alive = false;
        },
        load: (_, _) async {
          fail('Disposed editor must not request a frame.');
        },
      );
    },
  );
}
