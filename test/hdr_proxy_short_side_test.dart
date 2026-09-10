// HDR 代理的短邊比 SDR 工作檔小：代理只餵預覽跟縮圖，合成畫布實測
// 720x1280／900x1600 都用不到 1080，多編的像素直接變成進場等待
//（202 診斷：進場 41 秒全部是代理，工作檔 0 支）。
//
// 這條測試釘的不是「900 這個數字」，是兩件不能默默壞掉的事：
//   1. ensureHdr 真的有把 maxShortSide 傳下去——那一行被刪掉不會報錯，
//      只會無聲退回 toWorkFile 的 1080 預設值，省下的時間全部吐回去
//   2. SDR 工作檔那條維持 1080：它餵匯出，跟著調小就是成品畫質退步

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
  const channel = MethodChannel('markcut/prep');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    dir = Directory.systemTemp.createTempSync('markcut_proxy_short_');
    source = '${dir.path}/source.mov';
    File(source).writeAsStringSync('original');
    WorkFiles.supportDirOverride = dir;
    WorkFiles.holdSweep = true;
    calls = [];
    hdr = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'probeLite':
          // 4K HDR：不會走「規格已合、免轉直用」那條捷徑
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
          File(args['dest'] as String).writeAsStringSync('encoded');
          return args['dest'];
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

  test('HDR 代理短邊比 1080 小，而且真的傳到原生端（漏傳＝無聲退回預設值）', () async {
    hdr = true;
    final made = await WorkFiles.ensureHdr(source);
    expect(made, isNotNull);
    expect(calls.single['hdr'], true);
    expect(
      calls.single['maxShortSide'],
      WorkFiles.kHdrProxyShortSide,
      reason: 'ensureHdr 沒把 maxShortSide 傳下去，原生端會吃 1080 的預設值',
    );
    expect(
      WorkFiles.kHdrProxyShortSide,
      lessThan(1080),
      reason: '代理跟工作檔一樣大就沒有省到，進場等待會退回原樣',
    );
  });

  test('SDR 工作檔維持 1080：它餵匯出，不能跟著代理調小', () async {
    hdr = false;
    final made = await WorkFiles.ensure(source);
    expect(made, isNotNull);
    expect(calls.single['hdr'], isNull);
    expect(
      calls.single['maxShortSide'],
      1080,
      reason: '工作檔是匯出來源之一，短邊調小＝成品畫質退步',
    );
  });
}
