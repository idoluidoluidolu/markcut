import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/scrub_frame_queue.dart';

ScrubFrameRequest frame(int slot, {int source = 0, String path = 'raw.mov'}) =>
    ScrubFrameRequest(
      source: source,
      path: path,
      slot: slot,
      seconds: slot / 14,
    );

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('failed in-flight decode does not block the latest viewport', () async {
    final first = Completer<int?>();
    final delivered = <int>[];
    final q = ScrubFrameQueue<int>(
      canRun: () => true,
      load: (r) => r.slot == 0 ? first.future : Future.value(r.slot),
      onFrame: (_, value) => delivered.add(value),
    );
    q.request([frame(0)]);
    q.request([frame(100)]);
    first.completeError(StateError('decoder unavailable'));
    await tick();
    expect(delivered, [100]);
    q.dispose();
  });
  test(
    'requesting the same frame after invalidation decodes it again',
    () async {
      final first = Completer<int?>();
      var calls = 0;
      final delivered = <int>[];
      final q = ScrubFrameQueue<int>(
        canRun: () => true,
        load: (_) => ++calls == 1 ? first.future : Future.value(2),
        onFrame: (_, value) => delivered.add(value),
      );
      q.request([frame(0)]);
      q.clear();
      q.request([frame(0)]);
      first.complete(1);
      await tick();
      expect(calls, 2);
      expect(delivered, [2]);
      q.dispose();
    },
  );

  test(
    'rapid jumps discard queued positions; only one decode is in flight',
    () async {
      final starts = <int>[];
      final pending = <Completer<int?>>[];
      final q = ScrubFrameQueue<int>(
        canRun: () => true,
        load: (r) {
          starts.add(r.slot);
          final c = Completer<int?>();
          pending.add(c);
          return c.future;
        },
        onFrame: (_, _) {},
      );
      q.request([frame(0), frame(1)]);
      q.request([frame(40), frame(41)]);
      q.request([frame(80), frame(81)]);
      expect(starts, [0]);
      pending[0].complete(0);
      await tick();
      expect(starts, [0, 80]);
      pending[1].complete(80);
      await tick();
      expect(starts, [0, 80, 81]);
      q.dispose();
      pending[2].complete(81);
      await tick();
    },
  );

  test(
    'same in-flight frame is not decoded again; visible layers precede neighbours',
    () async {
      final first = Completer<int?>();
      final starts = <ScrubFrameRequest>[];
      final q = ScrubFrameQueue<int>(
        canRun: () => true,
        load: (r) async {
          starts.add(r);
          if (starts.length == 1) return first.future;
          return r.slot;
        },
        onFrame: (_, _) {},
      );
      final a = frame(5);
      final b = frame(5, source: 1);
      q.request([a]);
      q.request([a, b, b, frame(6)]);
      first.complete(5);
      await tick();
      expect(starts, [a, b, frame(6)]);
      q.dispose();
    },
  );

  test(
    'playback stops pending work and suppresses late preview delivery',
    () async {
      var allowed = true;
      final first = Completer<int?>();
      final delivered = <int>[];
      var calls = 0;
      final q = ScrubFrameQueue<int>(
        canRun: () => allowed,
        load: (_) {
          calls++;
          return first.future;
        },
        onFrame: (_, value) => delivered.add(value),
      );
      q.request([frame(0), frame(1)]);
      allowed = false;
      first.complete(0);
      await tick();
      expect(calls, 1);
      expect(delivered, isEmpty);
      q.dispose();
    },
  );

  test(
    'clear invalidates an old decode even if playback has already stopped',
    () async {
      final first = Completer<int?>();
      final delivered = <int>[];
      final q = ScrubFrameQueue<int>(
        canRun: () => true,
        load: (r) => r.slot == 0 ? first.future : Future.value(r.slot),
        onFrame: (_, value) => delivered.add(value),
      );
      q.request([frame(0)]);
      q.clear();
      q.request([frame(100, path: 'work.mp4')]);
      first.complete(0);
      await tick();
      expect(delivered, [100]);
      q.dispose();
    },
  );

  test(
    'leaving the editor ignores in-flight results and new requests',
    () async {
      final first = Completer<int?>();
      var calls = 0;
      final delivered = <int>[];
      final q = ScrubFrameQueue<int>(
        canRun: () => true,
        load: (_) {
          calls++;
          return first.future;
        },
        onFrame: (_, value) => delivered.add(value),
      );
      q.request([frame(0)]);
      q.dispose();
      q.request([frame(1)]);
      first.complete(0);
      await tick();
      expect(calls, 1);
      expect(delivered, isEmpty);
    },
  );
}
