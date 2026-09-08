import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String source;
  late List<Map<dynamic, dynamic>> calls;
  var hdr = false;
  var defer = true;
  const channel = MethodChannel('markcut/prep');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    dir = Directory.systemTemp.createTempSync('markcut_prep_yield_');
    source = '${dir.path}/source.mov';
    File(source).writeAsStringSync('original');
    WorkFiles.supportDirOverride = dir;
    WorkFiles.holdSweep = true;
    calls = [];
    hdr = false;
    defer = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'probeLite':
          return {
            'w': 2160,
            'h': 3840,
            'codec': 'hvc1',
            'durSec': 10.0,
            'sdr709': !hdr,
          };
        case 'toWorkFile':
          final args = Map<dynamic, dynamic>.from(call.arguments as Map);
          calls.add(args);
          File(args['dest'] as String).writeAsStringSync('encoded-part');
          return defer
              ? {'status': 'deferred', 'reason': 'interaction'}
              : args['dest'];
      }
      return null;
    });
    await MediaPrep.setInteractive(false);
  });

  tearDown(() async {
    await MediaPrep.setInteractive(false);
    messenger.setMockMethodCallHandler(channel, null);
    WorkFiles.supportDirOverride = null;
    WorkFiles.holdSweep = false;
    WorkFiles.resetForTest();
    dir.deleteSync(recursive: true);
  });

  for (final isHdr in [false, true]) {
    test(
      '${isHdr ? 'HDR' : 'SDR'} deferred encode is not failure and leaves no partial',
      () async {
        hdr = isHdr;
        Future<String?> prepare() => isHdr
            ? WorkFiles.ensureHdr(source, interactiveYield: true)
            : WorkFiles.ensure(source, interactiveYield: true);
        await expectLater(
          prepare(),
          throwsA(isA<PreviewPreparationDeferred>()),
        );
        expect(calls.single['interactiveYield'], true);
        expect(WorkFiles.needsSafeRetry(source), false);
        expect(WorkFiles.isPreparing(source), false);
        expect(File(calls.single['dest'] as String).existsSync(), false);
        expect(await WorkFiles.lookup(source), isNull);
        expect(await WorkFiles.lookupHdr(source), isNull);
        // Idle retry keeps identical encoding quality and can still succeed.
        defer = false;
        final result = await prepare();
        expect(result, isNotNull);
        expect(calls.length, 2);
        expect(calls.last['safe'], isNull);
        expect(calls.last['hdr'], isHdr ? true : null);
        expect(File(result!).existsSync(), true);
      },
    );
  }

  test(
    'busy preview never enters native queue; export jobs are unaffected',
    () async {
      await MediaPrep.setInteractive(true);
      await expectLater(
        MediaPrep.toWorkFile(
          source,
          '${dir.path}/preview.mp4',
          interactiveYield: true,
        ),
        throwsA(isA<PreviewPreparationDeferred>()),
      );
      expect(calls, isEmpty);
      defer = false;
      expect(
        await MediaPrep.toWorkFile(source, '${dir.path}/export.mp4'),
        '${dir.path}/export.mp4',
      );
      expect(calls.single['interactiveYield'], isNull);
    },
  );
}
