import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/media_prep.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('markcut/prep');
  final sent = <Map<dynamic, dynamic>>[];
  setUp(() {
    sent.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'setInteractive') sent.add(call.arguments as Map);
          return null;
        });
  });
  tearDown(() async {
    await MediaPrep.setInteractive(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'gesture can pause and resume decoding while playback remains interactive',
    () async {
      await MediaPrep.setInteractive(true);
      await MediaPrep.setInteractive(true, pauseDecoding: true);
      await MediaPrep.setInteractive(true);
      await MediaPrep.setInteractive(false, pauseDecoding: true);
      expect(sent, [
        {'interactive': true, 'pauseDecoding': false},
        {'interactive': true, 'pauseDecoding': true},
        {'interactive': true, 'pauseDecoding': false},
        {'interactive': false, 'pauseDecoding': false},
      ]);
      expect(MediaPrep.debugScheduling.interactive, isFalse);
    },
  );

  test(
    'gesture during start recording defers native allocation and frees slot',
    () async {
      final entered = Completer<void>();
      final recorded = Completer<void>();
      var nativeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'available') return true;
            if (call.method == 'toWorkFile') nativeCalls++;
            return null;
          });
      await MediaPrep.setInteractive(false);
      final work = MediaPrep.toWorkFile(
        '/source.mov',
        '/proxy.mp4',
        interactiveYield: true,
        onStart: () async {
          entered.complete();
          await recorded.future;
        },
      );
      final deferred = expectLater(
        work,
        throwsA(isA<PreviewPreparationDeferred>()),
      );
      await entered.future;
      expect(nativeCalls, 0);
      expect(MediaPrep.debugScheduling.running, 1);
      await MediaPrep.setInteractive(true, pauseDecoding: true);
      recorded.complete();
      await deferred;
      expect(nativeCalls, 0);
      expect(MediaPrep.debugScheduling.running, 0);
      expect(MediaPrep.debugScheduling.waiting, 0);
    },
  );

  for (final hdr in [false, true]) {
    test(
      'memory deferral preserves retry delay and releases job slot (HDR=$hdr)',
      () async {
        var calls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'available') return true;
              if (call.method == 'toWorkFile') {
                calls++;
                return {'status': 'deferred', 'retryAfterMs': 5000};
              }
              return null;
            });
        await MediaPrep.setInteractive(false);
        await expectLater(
          MediaPrep.toWorkFile(
            '/source.mov',
            '/proxy.mp4',
            hdr: hdr,
            interactiveYield: true,
          ),
          throwsA(
            isA<PreviewPreparationDeferred>().having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 5),
            ),
          ),
        );
        expect(calls, 1, reason: 'no internal fallback or immediate retry');
        expect(MediaPrep.debugScheduling.running, 0);
        expect(MediaPrep.debugScheduling.waiting, 0);
      },
    );
  }
}
