import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('markcut/prep');
  final calls = <String>[];
  Object? eligibility;
  const complete = {'frames': 300, 'keyframes': 60, 'maxGopFrames': 5};

  setUp(() {
    calls.clear();
    eligibility = {'gopRejected': true};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'available':
              return true;
            case 'probeWorkEligibility':
              if (eligibility is Exception) throw eligibility!;
              return eligibility;
            case 'probe':
              return complete;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('sparse GOP returns early without running the full probe', () async {
    expect(await MediaPrep.probeWorkEligibility('long.mp4'), {
      'gopRejected': true,
    });
    expect(calls, contains('probeWorkEligibility'));
    expect(calls, isNot(contains('probe')));
  });

  test(
    'diagnostics retain complete counts after an eligibility rejection',
    () async {
      await MediaPrep.probeWorkEligibility('long.mp4');
      expect(await MediaPrep.probe('long.mp4'), complete);
      expect(calls.last, 'probe');
    },
  );

  test('accepted file returns complete eligibility statistics', () async {
    eligibility = complete;
    expect(await MediaPrep.probeWorkEligibility('dense.mp4'), complete);
    expect(calls, isNot(contains('probe')));
  });

  test(
    'early rejection triggers a prechecked transcode instead of copying',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'markcut_gop_eligibility_',
      );
      SharedPreferences.setMockInitialValues({});
      WorkFiles.resetForTest();
      WorkFiles.supportDirOverride = dir;
      WorkFiles.holdSweep = true;
      MediaPrep.resetProbeCacheForTest();
      addTearDown(() async {
        WorkFiles.supportDirOverride = null;
        WorkFiles.holdSweep = false;
        WorkFiles.resetForTest();
        await dir.delete(recursive: true);
      });
      final source = File('${dir.path}/source.mp4');
      await source.writeAsString('source');
      Map? transcode;
      var fullProbes = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'available':
                return true;
              case 'probeLite':
                return {
                  'w': 1080,
                  'h': 1920,
                  'codec': 'avc1',
                  'rotated': false,
                  'sdr709': true,
                };
              case 'probeWorkEligibility':
                return {'gopRejected': true};
              case 'probe':
                fullProbes++;
                return complete;
              case 'toWorkFile':
                transcode = call.arguments as Map;
                // Stop before output validation: this checks eligibility and
                // the contract that native code must not probe a second time.
                return null;
            }
            return null;
          });
      expect(await WorkFiles.ensure(source.path), isNull);
      expect(transcode, isNotNull);
      expect(transcode!['prechecked'], true);
      expect(fullProbes, 0);
    },
  );

  for (final unsupported in [null, MissingPluginException()]) {
    test(
      'unsupported native eligibility method falls back: $unsupported',
      () async {
        eligibility = unsupported;
        expect(await MediaPrep.probeWorkEligibility('old-build.mp4'), complete);
        expect(calls.last, 'probe');
      },
    );
  }
}
