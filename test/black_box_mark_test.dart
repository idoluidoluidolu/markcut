// 黑盒子（Diag.mark / clearMark / loadLastRun）：
//
// 209 那份「多支影片閃退」報告只留下「HDR 代理：轉檔中／2111 MB」，判不出
// 當時載了幾支、疊了幾軌、誰在跑。這裡釘住三件事：
//   1. 現場快照（Diag.sceneProvider）真的寫進黑盒子、下次開 App 印得出來
//   2. clearMark 之後半路上的 mark 不能再寫（不然正常結束也被冤枉成閃退）
//   3. 代理轉檔：排隊中 → 拿到槽才寫「轉檔中」→ 做完擦掉

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const diagCh = MethodChannel('markcut/diag');
  const prepCh = MethodChannel('markcut/prep');
  late Directory dir;

  File crumb() => File('${dir.path}${Platform.pathSeparator}last_run.json');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('markcut_blackbox_');
    Diag.crumbDirOverride = dir;
    Diag.sceneProvider = null;
    Diag.crumbFromLastRun = null;
    Diag.nativePrepDiagnostic = null;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(diagCh, null);
    messenger.setMockMethodCallHandler(prepCh, null);
    Diag.crumbDirOverride = null;
    Diag.sceneProvider = null;
    dir.deleteSync(recursive: true);
  });

  test('現場快照跟著 mark 寫進黑盒子，下次開 App 印得出來', () async {
    messenger.setMockMethodCallHandler(
      diagCh,
      (call) async => {'usedMb': 2111.0, 'freeMb': 1265.0},
    );
    Diag.sceneProvider = () => {'素材': 7, '軌': 7, '合成': '有'};
    await Diag.mark('HDR 代理：轉檔中', data: {'檔案': 'a.mov'});
    final j = jsonDecode(crumb().readAsStringSync()) as Map<String, dynamic>;
    expect(j['stage'], 'HDR 代理：轉檔中');
    expect(j['usedMb'], 2111);
    expect(j['檔案'], 'a.mov');
    expect(j['素材'], 7);
    expect(j['軌'], 7);
    await Diag.loadLastRun();
    expect(Diag.crumbFromLastRun, contains('素材=7'));
    expect(Diag.crumbFromLastRun, contains('軌=7'));
    expect(Diag.crumbFromLastRun, contains('2111 MB'));
    expect(crumb().existsSync(), false, reason: '讀過一次就要擦掉');
  });

  test('原生階段在 Dart 現場缺失或損毀時仍出現在報告', () async {
    messenger.setMockMethodCallHandler(diagCh, (call) async {
      if (call.method == 'nativePrepDiagnostic') {
        return {
          'launch': {
            'process': 'new-run',
            'memory': {'usedMB': 1400},
          },
          'previous': {
            'status': 'running',
            'lanes': {
              'video': {'phase': 'first-hdr-render'},
              'audio': {'phase': 'first-decode'},
            },
          },
        };
      }
      return null;
    });
    for (final corrupt in [false, true]) {
      if (corrupt) crumb().writeAsStringSync('{broken');
      await Diag.loadLastRun();
      expect(Diag.nativePrepDiagnostic, contains('first-hdr-render'));
      expect(Diag.nativePrepDiagnostic, contains('first-decode'));
      expect(Diag.crumbFromLastRun, isNull);
    }
  });

  test('clearMark 之後才寫完的 mark 要作廢：正常結束不能被冤枉成閃退', () async {
    // 讓記憶體查詢卡住：mark 在 await 裡等，這時 clearMark 先跑
    final gate = Completer<Map<String, double>>();
    messenger.setMockMethodCallHandler(diagCh, (call) => gate.future);
    final inFlight = Diag.mark('HDR 代理：轉檔中');
    await Future<void>.delayed(Duration.zero);
    await Diag.clearMark();
    gate.complete({'usedMb': 900.0, 'freeMb': 2000.0});
    await inFlight;
    expect(
      crumb().existsSync(),
      false,
      reason: '半路上的心跳 mark 在 clearMark 之後落地，會留下假現場',
    );
  });

  test('代理轉檔：拿到槽才寫「轉檔中」，做完擦掉', () async {
    messenger.setMockMethodCallHandler(
      diagCh,
      (call) async => {'usedMb': 700.0, 'freeMb': 2500.0},
    );
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    WorkFiles.supportDirOverride = dir;
    WorkFiles.holdSweep = true;
    addTearDown(() {
      WorkFiles.supportDirOverride = null;
      WorkFiles.holdSweep = false;
      WorkFiles.resetForTest();
    });
    final source = '${dir.path}/source.mov';
    File(source).writeAsStringSync('original');
    String? stageSeenByNative;
    messenger.setMockMethodCallHandler(prepCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'probeLite':
          return {
            'w': 2160,
            'h': 3840,
            'codec': 'hvc1',
            'durSec': 10.0,
            'sdr709': false,
          };
        case 'toWorkFile':
          // 原生被叫到的這一刻，黑盒子上必須已經是「轉檔中」（onStart 先跑）
          final j =
              jsonDecode(crumb().readAsStringSync()) as Map<String, dynamic>;
          stageSeenByNative = j['stage'] as String?;
          final args = Map<dynamic, dynamic>.from(call.arguments as Map);
          File(args['dest'] as String).writeAsStringSync('encoded');
          return args['dest'];
      }
      return null;
    });
    await MediaPrep.setInteractive(false);
    final made = await WorkFiles.ensureHdr(source);
    expect(made, isNotNull);
    expect(stageSeenByNative, 'HDR 代理：轉檔中');
    expect(crumb().existsSync(), false, reason: '做完要 clearMark');
  });
}
