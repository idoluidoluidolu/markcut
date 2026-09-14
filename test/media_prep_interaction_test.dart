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
}
