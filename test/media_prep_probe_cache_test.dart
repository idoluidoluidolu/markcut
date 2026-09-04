// probeLite 的快取：同一支檔匯入一趟會被問三次（接軌問長度、分類問
// HDR、做代理前再問一次），每次原生端都同步重解析 4K 的 moov。
// 內容不變就不用再問；內容換了（同一路徑被相簿暫存重複使用）要重問
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/media_prep.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('markcut/prep');
  late int calls;
  late Directory dir;

  setUp(() async {
    calls = 0;
    MediaPrep.resetProbeCacheForTest();
    dir = await Directory(
      '${Directory.current.path}${Platform.pathSeparator}build'
      '${Platform.pathSeparator}probe_cache_test',
    ).create(recursive: true);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (call) async {
          switch (call.method) {
            case 'available':
              return true;
            case 'probeLite':
              calls++;
              return <String, dynamic>{
                'w': 3840,
                'h': 2160,
                'codec': 'hvc1',
                'sdr709': false,
                'durSec': 3.0,
              };
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
    MediaPrep.resetProbeCacheForTest();
  });

  test('同一支檔問三次，原生端只被叫一次；結果是副本，改了不會污染快取', () async {
    final f = File('${dir.path}${Platform.pathSeparator}a.mov');
    await f.writeAsString('abc');
    final m1 = await MediaPrep.probeLite(f.path);
    final m2 = await MediaPrep.probeLite(f.path);
    m2!['w'] = 1;
    final m3 = await MediaPrep.probeLite(f.path);
    expect(calls, 1);
    expect(m1!['w'], 3840);
    expect(m3!['w'], 3840);
    await f.delete();
  });

  test('檔案內容換了（大小不同）要重問', () async {
    final f = File('${dir.path}${Platform.pathSeparator}b.mov');
    await f.writeAsString('abc');
    await MediaPrep.probeLite(f.path);
    await f.writeAsString('abcdef');
    await MediaPrep.probeLite(f.path);
    expect(calls, 2);
    await f.delete();
  });

  test('檔案不存在（stat 不到）就不進快取，每次都問', () async {
    final p = '${dir.path}${Platform.pathSeparator}missing.mov';
    await MediaPrep.probeLite(p);
    await MediaPrep.probeLite(p);
    expect(calls, 2);
  });
}
