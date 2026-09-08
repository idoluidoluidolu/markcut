import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/native_frames.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('markcut/frames');
  final bytes = Uint8List.fromList([1, 2, 3]);
  late List<MethodCall> calls;
  Object? response;

  setUp(() {
    calls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return response;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('詳細影格保留實際零秒，不回填要求的五秒', () async {
    response = {'bytes': bytes, 'actualSeconds': 0};
    final frame = await nativeFrameAtDetailed('/v.mov', 5, tolMs: 250);
    expect(frame!.bytes, bytes);
    expect(frame.actualSeconds, 0);
    expect(frame.usableForPreviewAt(5), false);
    expect(frame.usableForPreviewAt(0), true);
    expect(calls.single.arguments, containsPair('detailed', true));
    expect(calls.single.arguments, containsPair('ms', 5000));
  });

  test('Android或舊原生只回bytes時，時間未知但仍可作粗覽', () async {
    response = bytes;
    final frame = await nativeFrameAtDetailed('/v.mp4', 7.2);
    expect(frame!.actualSeconds, isNull);
    expect(frame.bytes, bytes);
    expect(frame.usableForPreviewAt(7.2), true);
  });

  test('已知取樣偏移必須按actualSeconds判斷距離', () {
    final frame = NativeFrameSample(bytes: bytes, actualSeconds: 2);
    expect(frame.usableForPreviewAt(5), false);
    expect(frame.usableForPreviewAt(2.2), true);
    expect(frame.usableForPreviewAt(1.5), false);
  });

  test('無效或缺少取樣時間不偽造精確時間，缺少bytes則拒收', () {
    for (final actual in [null, double.nan, double.infinity, -1, 'bad']) {
      final frame = NativeFrameSample.fromPlatform({
        'bytes': bytes,
        'actualSeconds': actual,
      });
      expect(frame!.actualSeconds, isNull);
    }
    expect(NativeFrameSample.fromPlatform({'actualSeconds': 0}), isNull);
    expect(NativeFrameSample.fromPlatform(null), isNull);
  });

  test('原本bytes API不要求詳細回覆，保留相容性', () async {
    response = bytes;
    expect(await nativeFrameAt('/v.mov', 3), bytes);
    expect(calls.single.arguments, isNot(contains('detailed')));
  });

  test('stats是抽幀器重用計數，release不帶媒體資料', () async {
    response = {'active': 2, 'created': 3, 'reused': 9, 'capacity': 2};
    expect(await readNativeFrameStats(), (
      active: 2,
      created: 3,
      reused: 9,
      capacity: 2,
    ));
    response = null;
    await releaseNativeFrames();
    expect(calls.last.method, 'release');
    expect(calls.last.arguments, isNull);
  });
}
