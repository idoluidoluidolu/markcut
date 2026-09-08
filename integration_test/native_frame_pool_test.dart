import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:markcut/services/native_frames.dart';

// Supply two distinct, locally accessible videos on the test device. This runs
// real native extraction; host-only Flutter tests do not validate codec behavior.
// --dart-define=FRAME_TEST_A=/.../a.mp4 --dart-define=FRAME_TEST_B=/.../b.mp4
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const pathA = String.fromEnvironment('FRAME_TEST_A');
  const pathB = String.fromEnvironment('FRAME_TEST_B');

  testWidgets(
    'native frame pool reuses alternating sources and releases all resources',
    (tester) async {
      expect(pathA, isNot(pathB));
      expect(File(pathA).existsSync(), isTrue, reason: 'FRAME_TEST_A missing');
      expect(File(pathB).existsSync(), isTrue, reason: 'FRAME_TEST_B missing');
      await tester.runAsync(() async {
        await releaseNativeFrames();
        final before = await readNativeFrameStats();
        expect(before, isNotNull, reason: 'Native pool stats unavailable');
        expect(before!.active, 0);
        try {
          for (final path in [pathA, pathB, pathA]) {
            final elapsed = Stopwatch()..start();
            final sample = await nativeFrameAtDetailed(path, 0, maxH: 320);
            expect(sample, isNotNull, reason: 'Native decode failed for $path');
            final codec = await ui.instantiateImageCodec(sample!.bytes);
            try {
              final decoded = await codec.getNextFrame();
              expect(decoded.image.width, greaterThan(0));
              expect(decoded.image.height, greaterThan(0));
              decoded.image.dispose();
            } finally {
              codec.dispose();
            }
            if (Platform.isAndroid) expect(sample.actualSeconds, isNull);
            debugPrint(
              'NATIVE_FRAME ${File(path).uri.pathSegments.last} '
              '${elapsed.elapsedMilliseconds}ms bytes=${sample.bytes.length} '
              'actual=${sample.actualSeconds ?? "unknown"}',
            );
          }
          final after = (await readNativeFrameStats())!;
          expect(after.active, 2);
          expect(after.created - before.created, 2);
          expect(after.reused - before.reused, 1);
          // Old callers still receive bytes after detailed callers have used the pool.
          expect(await nativeFrameAt(pathA, 0, maxH: 320), isNotEmpty);
        } finally {
          await releaseNativeFrames();
        }
        expect((await readNativeFrameStats())!.active, 0);
      });
    },
    skip: pathA.isEmpty || pathB.isEmpty,
  );
}
