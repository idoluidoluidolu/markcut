import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/player_value.dart';
import 'package:markcut/services/video_controller_io.dart';

class _Player implements PlayerX {
  @override
  final path = 'fixture.mp4';
  Completer<void>? initializing;
  Completer<void>? starting;
  Completer<void>? seeking;
  bool failInitialize = false;
  bool failPlay = false;
  bool playing = false;
  int disposed = 0;
  Duration position = const Duration(seconds: 3);
  final events = <String>[];

  @override
  Future<void> initialize() async {
    events.add('initialize');
    if (initializing != null) await initializing!.future;
    if (failInitialize) throw StateError('first frame timed out');
  }

  @override
  Future<void> play() async {
    events.add('play');
    if (starting != null) await starting!.future;
    if (failPlay) throw StateError('decoder failed');
    playing = true;
  }

  @override
  Future<void> pause() async {
    events.add('pause');
    playing = false;
  }

  @override
  Future<void> seekTo(Duration d) async {
    events.add('seek:${d.inMilliseconds}');
    if (seeking != null) await seeking!.future;
    position = d;
  }

  @override
  Future<Duration?> positionNow() async => position;
  @override
  Future<void> setVolume(double value) async {
    events.add('volume:$value');
  }

  @override
  Future<void> setPlaybackSpeed(double value) async {
    events.add('rate:$value');
  }

  @override
  Future<void> setLooping(bool value) async {
    events.add('loop:$value');
  }

  @override
  void dispose() {
    disposed++;
  }

  @override
  String get debugInfo => 'fake';
  @override
  Widget view({Key? key}) => SizedBox(key: key);
  @override
  PlayerValueX get value => PlayerValueX(
    isInitialized: true,
    isPlaying: playing,
    duration: const Duration(seconds: 10),
    position: position,
    size: const Size(100, 100),
  );
}

Future<void> _flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'late initialization failure after disposal never creates a replacement',
    () async {
      final primary = _Player()
        ..initializing = Completer<void>()
        ..failInitialize = true;
      var replacements = 0;
      final controller = PlayerX.fallbackForTesting(
        primary.path,
        primary: (_) => primary,
        fallback: (_) {
          replacements++;
          return _Player();
        },
      );
      final opening = controller.initialize();
      controller.dispose();
      primary.initializing!.complete();
      await opening;
      expect(replacements, 0);
      expect(primary.disposed, 1);
    },
  );

  test(
    'confirmed first-frame failure falls back without starting playback',
    () async {
      final primary = _Player()..failInitialize = true;
      final fallback = _Player();
      final controller = PlayerX.fallbackForTesting(
        primary.path,
        primary: (_) => primary,
        fallback: (_) => fallback,
      );
      await controller.initialize();
      expect(primary.disposed, 1);
      expect(fallback.events, [
        'initialize',
        'volume:1.0',
        'rate:1.0',
        'loop:false',
      ]);
      controller.dispose();
      expect(fallback.disposed, 1);
    },
  );

  for (final action in ['pause', 'seek', 'dispose']) {
    test(
      'a $action during a pending play failure prevents stale fallback',
      () async {
        final primary = _Player()
          ..starting = Completer<void>()
          ..failPlay = true;
        var replacements = 0;
        final controller = PlayerX.fallbackForTesting(
          primary.path,
          primary: (_) => primary,
          fallback: (_) {
            replacements++;
            return _Player();
          },
        );
        await controller.initialize();
        final playing = controller.play();
        if (action == 'pause') await controller.pause();
        if (action == 'seek') {
          await controller.seekTo(const Duration(seconds: 7));
        }
        if (action == 'dispose') controller.dispose();
        primary.starting!.complete();
        await playing;
        expect(replacements, 0);
        if (action == 'seek') {
          expect(primary.position, const Duration(seconds: 7));
        }
        controller.dispose();
        expect(primary.disposed, 1);
      },
    );

    test(
      'a $action while fallback initializes disposes it without restoring stale state',
      () async {
        final primary = _Player()..failPlay = true;
        final fallback = _Player()..initializing = Completer<void>();
        final controller = PlayerX.fallbackForTesting(
          primary.path,
          primary: (_) => primary,
          fallback: (_) => fallback,
        );
        await controller.initialize();
        final playing = controller.play();
        await _flush();
        expect(fallback.events, ['initialize']);
        if (action == 'pause') await controller.pause();
        if (action == 'seek') {
          await controller.seekTo(const Duration(seconds: 7));
        }
        if (action == 'dispose') controller.dispose();
        expect(fallback.disposed, 1);
        fallback.initializing!.complete();
        await playing;
        expect(fallback.events, ['initialize']);
        expect(fallback.disposed, 1);
        controller.dispose();
      },
    );
  }

  test(
    'play error fallback restores position and settings before resuming',
    () async {
      final primary = _Player()..failPlay = true;
      final fallback = _Player();
      final controller = PlayerX.fallbackForTesting(
        primary.path,
        primary: (_) => primary,
        fallback: (_) => fallback,
      );
      await controller.initialize();
      await controller.setVolume(0.25);
      await controller.setPlaybackSpeed(0.5);
      await controller.setLooping(true);
      await controller.play();
      expect(fallback.events, [
        'initialize',
        'volume:0.25',
        'rate:0.5',
        'loop:true',
        'seek:3000',
        'play',
      ]);
      expect(primary.disposed, 1);
      controller.dispose();
    },
  );

  test(
    'pause while fallback restores its position prevents a later play',
    () async {
      final primary = _Player()..failPlay = true;
      final fallback = _Player()..seeking = Completer<void>();
      final controller = PlayerX.fallbackForTesting(
        primary.path,
        primary: (_) => primary,
        fallback: (_) => fallback,
      );
      await controller.initialize();
      final playing = controller.play();
      await _flush();
      expect(fallback.events.last, 'seek:3000');
      await controller.pause();
      fallback.seeking!.complete();
      await playing;
      expect(fallback.events, isNot(contains('play')));
      expect(fallback.disposed, 1);
      expect(primary.disposed, 0);
      controller.dispose();
    },
  );

  testWidgets(
    'healthy first playback does not extract an unrelated sync frame or replace backend',
    (tester) async {
      var frameRequests = 0;
      var replacements = 0;
      const channel = MethodChannel('markcut/frames');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        frameRequests++;
        return null;
      });
      final primary = _Player();
      final controller = PlayerX.fallbackForTesting(
        primary.path,
        primary: (_) => primary,
        fallback: (_) {
          replacements++;
          return _Player();
        },
      );
      await controller.initialize();
      await controller.play();
      await tester.pump(const Duration(seconds: 2));
      expect(frameRequests, 0);
      expect(replacements, 0);
      controller.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    },
  );

  for (final useFallback in [false, true]) {
    test(
      'pause wins over late ${useFallback ? 'replacement' : 'primary'} play completion',
      () async {
        final primary = _Player()..failPlay = useFallback;
        final fallback = _Player();
        final target = useFallback ? fallback : primary;
        target.starting = Completer<void>();
        final controller = PlayerX.fallbackForTesting(
          primary.path,
          primary: (_) => primary,
          fallback: (_) => fallback,
        );
        await controller.initialize();
        final playing = controller.play();
        await _flush();
        expect(target.events, contains('play'));
        await controller.pause();
        target.starting!.complete();
        await playing;
        expect(target.playing, false);
        expect(target.events.last, 'pause');
        controller.dispose();
      },
    );
  }

  test(
    'settings changed during replacement seek apply without cancelling recovery',
    () async {
      final primary = _Player()..failPlay = true;
      final fallback = _Player()..seeking = Completer<void>();
      final controller = PlayerX.fallbackForTesting(
        primary.path,
        primary: (_) => primary,
        fallback: (_) => fallback,
      );
      await controller.initialize();
      final playing = controller.play();
      await _flush();
      await controller.setVolume(0.2);
      await controller.setPlaybackSpeed(1.5);
      fallback.seeking!.complete();
      await playing;
      expect(fallback.disposed, 0);
      expect(fallback.events.sublist(fallback.events.length - 4), [
        'volume:0.2',
        'rate:1.5',
        'loop:false',
        'play',
      ]);
      controller.dispose();
    },
  );
}
