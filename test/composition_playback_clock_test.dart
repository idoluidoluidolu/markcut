import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/composition_playback_clock.dart';

void main() {
  late CompositionPlaybackClock clock;

  setUp(() => clock = CompositionPlaybackClock()..reset(0));

  void sample(double? position, {double end = 5, double visible = 5}) {
    clock.sample(
      nativePosition: position,
      compositionDuration: end,
      visibleDuration: visible,
    );
  }

  test('startup and repeated stalled positions never advance the playhead', () {
    for (var i = 0; i < 60; i++) {
      sample(0);
      clock.advanceTail(1 / 30, visibleDuration: 5);
    }
    expect(clock.position, 0);
    sample(1.237);
    for (var i = 0; i < 60; i++) {
      sample(1.237);
      clock.advanceTail(1 / 30, visibleDuration: 5);
    }
    expect(clock.position, 1.237);
    sample(1.27);
    expect(clock.position, 1.27);
  });

  test('missing or invalid native samples hold the previous position', () {
    sample(2);
    for (final p in [null, double.nan, double.infinity, -1.0]) {
      sample(p);
      expect(clock.position, 2);
    }
  });

  test('a stall near the last frame cannot start the visible tail', () {
    sample(4.95, visible: 7);
    clock.advanceTail(1, visibleDuration: 7);
    expect(clock.position, 4.95);
    expect(clock.inTail, isFalse);
  });

  test(
    'confirmed composition end releases the visible tail and reaches end',
    () {
      sample(4.999, visible: 7);
      expect(clock.inTail, isTrue);
      expect(clock.position, 5);
      clock.advanceTail(0.5, visibleDuration: 7);
      sample(5, visible: 7);
      expect(
        clock.position,
        5.5,
        reason: 'the stopped player cannot rewind a tail',
      );
      clock.advanceTail(2, visibleDuration: 7);
      expect(clock.position, 7);
    },
  );

  test('resume inside a tail preserves its requested position', () {
    clock.reset(6);
    sample(4.966, visible: 7);
    clock.advanceTail(0.02, visibleDuration: 7);
    expect(
      clock.position,
      6,
      reason: 'wait for a seek clamped to the last frame',
    );
    expect(clock.inTail, isFalse);
    sample(5, visible: 7);
    expect(clock.position, 6);
    clock.advanceTail(0.5, visibleDuration: 7);
    expect(clock.position, 6.5);
  });

  test('replay resets the tail state and requires new native progress', () {
    sample(5, visible: 7);
    clock.advanceTail(1, visibleDuration: 7);
    clock.reset(0);
    sample(0, visible: 7);
    clock.advanceTail(1, visibleDuration: 7);
    expect(clock.position, 0);
    expect(clock.inTail, isFalse);
  });

  test(
    'millisecond rounding reaches the end without exceeding visible content',
    () {
      sample(4.999, end: 4.9995, visible: 4.9995);
      expect(clock.position, 4.9995);
      expect(clock.inTail, isFalse);
      sample(5.03, end: 5.54, visible: 5);
      expect(clock.position, 5);
    },
  );
}
