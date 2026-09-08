import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/photo_saver_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gal');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('拒絕相簿權限要失敗，不得回傳成功結果或寫入照片', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return false;
    });

    await expectLater(
      savePhotoPng(Uint8List.fromList([1]), 'test'),
      throwsA(
        isA<PhotoSavePermissionException>().having(
          (e) => e.toString(),
          '提示',
          contains('請到系統設定開啟'),
        ),
      ),
    );
    expect(calls, ['hasAccess', 'requestAccess']);
  });

  test('允許相簿權限後才寫入並回傳成功', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'hasAccess') return false;
      if (call.method == 'requestAccess') return true;
      return null;
    });

    expect(await savePhotoPng(Uint8List.fromList([1]), 'test'), '已存到「浮水印」相簿');
    expect(calls.first, 'hasAccess');
    expect(calls, contains('requestAccess'));
    expect(calls.last, 'putImageBytes');
    expect(calls.where((call) => call == 'putImageBytes'), hasLength(1));
  });
}
