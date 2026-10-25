// 保險絲（Diag.fuseOn／fuseOff／fuseReset＋loadLastRun）：
//
// 10-25 Android 一匯入照片進馬賽克模式就閃退。原生那邊包得再緊，ML Kit
// 自己的執行緒或原生程式庫炸了還是接不住——這裡釘住：
//   1. 找臉的原生呼叫進行中，記號已經在磁碟上（原生一炸就來不及寫）
//   2. 原生回來（成功、失敗都算）記號就刪，失敗原因留著給提示用
//   3. 下一趟開 App 讀到還在的記號：首頁跳報告、標題講明，自動找臉暫停
//   4. 暫停跨趟有效，直到找成功一次
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/face_detect.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const faceCh = MethodChannel('markcut/face');
  const line = '上次 App 在「自動找臉」途中被關掉了';
  late Directory dir;

  File fuse({bool paused = false}) => File(
    '${dir.path}${Platform.pathSeparator}'
    'fuse_face${paused ? '_paused' : ''}.json',
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('markcut_fuse_');
    Diag.crumbDirOverride = dir;
    Diag.crumbFromLastRun = null;
    Diag.nativePrepDiagnostic = null;
    Diag.recoveredReport.value = null;
    Diag.fusePaused.clear();
    FaceDetect.lastError = null;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(faceCh, null);
    Diag.recoveredReport.value = null;
    Diag.fusePaused.clear();
    Diag.crumbDirOverride = null;
    dir.deleteSync(recursive: true);
  });

  test('找臉途中記號已經在磁碟上，回來就刪', () async {
    bool? during;
    messenger.setMockMethodCallHandler(faceCh, (call) async {
      during = fuse().existsSync();
      return [
        {'x': 0.2, 'y': 0.2, 'w': 0.2, 'h': 0.2},
      ];
    });
    expect(await FaceDetect.inPhoto('/p.jpg'), hasLength(1));
    expect(during, isTrue, reason: '原生一炸就來不及寫：呼叫前就要在磁碟上');
    expect(fuse().existsSync(), isFalse, reason: '回來了還留著，下次開 App 會被冤枉成閃退');
    expect(FaceDetect.lastError, isNull);
  });

  test('原生回失敗：記號照樣刪，原因留著', () async {
    messenger.setMockMethodCallHandler(faceCh, (call) async {
      throw PlatformException(
        code: 'face_failed',
        message: 'IllegalStateException: boom',
      );
    });
    expect(await FaceDetect.inPhoto('/p.jpg'), isNull);
    expect(FaceDetect.lastError, 'IllegalStateException: boom');
    expect(fuse().existsSync(), isFalse);
  });

  test('失敗原因太長：提示只放前 160 字（哪一步、哪個類別在前面）', () async {
    final long = '偵測｜NullPointerException @ zzab.zza ← zzcd.zzb｜${'x' * 300}';
    messenger.setMockMethodCallHandler(faceCh, (call) async {
      throw PlatformException(code: 'face_failed', message: long);
    });
    expect(await FaceDetect.inPhoto('/p.jpg'), isNull);
    expect(FaceDetect.lastError, long);
    expect(FaceDetect.lastErrorBrief, '${long.substring(0, 160)}…');
  });

  test('上一趟死在找臉裡：跳報告、暫停自動找；暫停跨趟有效，找成功一次才恢復', () async {
    // 上一趟：記號寫了、原生還沒回來 App 就被收掉
    await Diag.fuseOn(FaceDetect.fuseKey, '自動找臉');
    await Diag.loadLastRun();
    final report = Diag.recoveredReport.value;
    expect(report, contains(line));
    expect(Diag.recoveredHeadline(report!), '上次 App 在自動找臉途中被關掉了，已保留報告。');
    expect(Diag.fusePaused, {FaceDetect.fuseKey: '自動找臉'});
    expect(fuse().existsSync(), isFalse);
    expect(fuse(paused: true).existsSync(), isTrue);

    // 再下一趟：同一件事不再多寫一次報告，但照樣暫停
    await Diag.loadLastRun();
    expect(Diag.fusePaused, {FaceDetect.fuseKey: '自動找臉'});
    expect(line.allMatches(Diag.recoveredReport.value ?? '').length, 1);

    // 自己按、找成功一次（沒有臉也算成功）：恢復
    messenger.setMockMethodCallHandler(faceCh, (call) async => <Object?>[]);
    expect(await FaceDetect.inPhoto('/p.jpg'), isEmpty);
    expect(Diag.fusePaused, isEmpty);
    expect(fuse(paused: true).existsSync(), isFalse);
    await Diag.loadLastRun();
    expect(Diag.fusePaused, isEmpty);
  });

  test('找失敗不算恢復：暫停留著', () async {
    await Diag.fuseOn(FaceDetect.fuseKey, '自動找臉');
    await Diag.loadLastRun();
    messenger.setMockMethodCallHandler(faceCh, (call) async {
      throw PlatformException(code: 'face_failed', message: 'x');
    });
    expect(await FaceDetect.inPhoto('/p.jpg'), isNull);
    expect(Diag.fusePaused, {FaceDetect.fuseKey: '自動找臉'});
    expect(fuse(paused: true).existsSync(), isTrue);
  });
}
