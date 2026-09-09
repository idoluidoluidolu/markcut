// 秒進之後每支工作檔一落地就換進合成（閒置時），不等整批。
//
// 實測 198：空白專案一次加六支 4K，五支短的代理幾秒就好、48 秒那支要
// 十幾秒；以前合成要等整批轉完才換，期間「在播的檔 6（原檔！）」——滑動
// 全走原檔的疏關鍵幀。這裡用真的編輯頁跑兩支素材：第一支假轉 0.4 秒、
// 第二支 1.6 秒，守「第一支落地、第二支還在轉」那段時間裡合成已經重組成
// [第一支工作檔, 第二支原檔]；整批做完再換成兩支都是工作檔。
//
// 假的原生端跟 import_eta_gate_test 同一套：素材是 HEVC SDR（規格不合＝
// 一定要轉），toWorkFile 花掉這支該花的時間才回
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/export_eta.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/timeline_strip.dart';
import 'package:markcut/services/work_files.dart';

import 'editor_harness.dart' show editorOf, solidPng;

late Directory _dir;
final _workArguments = <Map<Object?, Object?>>[];

/// 假轉檔端做完幾支（寫完 dest 才算）
var _workDone = 0;

/// 假抽幀端收到的路徑（依序）：縮圖帶從哪個檔抽的，看這裡
final _framePaths = <String>[];

/// 每支素材：多長、假的原生端要轉多久
const _videos = <String, ({double dur, int workMs})>{
  'first.mov': (dur: 20.0, workMs: 400),
  'second.mov': (dur: 40.0, workMs: 1600),
};

String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

/// 真的讓時間過去（假的原生端用 Future.delayed 模擬轉檔），
/// 同時把 widget 的時鐘往前推（閒置換檔的計時器要走）
Future<void> _settle(WidgetTester t, int steps) async {
  for (var i = 0; i < steps; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 等到 [ok] 成立，最多 [steps] 格（每格約 80ms）
Future<void> _until(
  WidgetTester t,
  bool Function() ok,
  int steps,
  String why,
) async {
  for (var i = 0; i < steps && !ok(); i++) {
    await _settle(t, 1);
  }
  expect(ok(), isTrue, reason: why);
}

/// 測試主機沒有 libmpv：編輯器要建預覽播放器就會丟這個。
/// 跟這一頁要守的東西無關，吞掉——但只吞這一種
void _swallowMediaKit(WidgetTester t) {
  for (;;) {
    final e = t.takeException();
    if (e == null) return;
    expect('$e', contains('MediaKit'), reason: '只有「測試主機沒有 libmpv」可以吞');
  }
}

void main() {
  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('markcut_prep_swap_');
    for (final n in _videos.keys) {
      File(_p(n)).writeAsStringSync('video $n');
    }
    WorkFiles.supportDirOverride = _dir;
    WorkFiles.holdSweep = false;

    final b = TestWidgetsFlutterBinding.ensureInitialized();
    for (final ch in const [
      'com.llfbandit.record/messages',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _dir.path,
    );
    b.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.arthenica.com/ffmpeg_kit'),
      (_) async => null,
    );
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/prep'),
      (call) async {
        switch (call.method) {
          case 'available':
            return true;
          case 'probeLite':
            final path = call.arguments as String;
            final v = _videos[path.split(Platform.pathSeparator).last];
            return <String, dynamic>{
              'w': 3840,
              'h': 2160,
              'codec': 'hvc1',
              'rotated': false,
              'sdr709': true, // SDR：走工作檔那條
              'durSec': v?.dur ?? 5.0,
            };
          case 'toWorkFile':
            final a = call.arguments as Map<Object?, Object?>;
            _workArguments.add(a);
            final src = a['src'] as String;
            final dest = a['dest'] as String;
            final v = _videos[src.split(Platform.pathSeparator).last];
            await Future<void>.delayed(
              Duration(milliseconds: v?.workMs ?? 100),
            );
            await File(dest).writeAsString('work');
            _workDone++;
            return dest;
        }
        return null;
      },
    );
    // 縮圖帶：每格都給，回報實際時間＝要的時間
    final frame = solidPng(0, 255, 0);
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/frames'),
      (call) async {
        if (call.method != 'frameAt') return null;
        final a = Map<Object?, Object?>.from(call.arguments as Map);
        _framePaths.add(a['path'] as String);
        return <String, Object?>{
          'bytes': frame,
          'actualSeconds': (a['ms'] as num) / 1000,
        };
      },
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    ImportEta.resetLearnedTail();
    _workArguments.clear();
    _workDone = 0;
    _framePaths.clear();
  });

  tearDownAll(() {
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('秒進：第一支工作檔落地就換進合成（第二支還在轉），整批做完再全換', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final builds = <List<String>>[];
    final oldLayer = Diag.playerLayer.value;
    Diag.playerLayer.value = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('markcut/comp'), (
      call,
    ) async {
      if (call.method == 'available') return true;
      if (call.method == 'build') {
        final clips = (call.arguments as Map)['clips'] as List;
        builds.add([for (final c in clips) (c as Map)['path'] as String]);
        return <String, dynamic>{
          'textureId': 1,
          'duration': 60.0,
          'width': 1920.0,
          'height': 1080.0,
        };
      }
      return null;
    });
    addTearDown(() {
      Diag.playerLayer.value = oldLayer;
      messenger.setMockMethodCallHandler(
        const MethodChannel('markcut/comp'),
        null,
      );
    });

    await t.pumpWidget(
      MaterialApp(
        home: VideoEditorScreen(
          videoPaths: [_p('first.mov'), _p('second.mov')],
        ),
      ),
    );
    // 首合成：兩支都還是原檔（秒進不等轉檔）
    await _until(t, () => builds.isNotEmpty, 50, '首合成要組起來');
    _swallowMediaKit(t);
    expect(builds.first, [_p('first.mov'), _p('second.mov')]);

    // 縮圖帶：進場粗帶 10 格之後馬上精抽成一秒一格（20 秒＝20 格），
    // 不等整批轉完——這時第二支還沒轉好
    await _until(
      t,
      () => (editorOf(t).thumbs[0]?.length ?? 0) == thumbStripCount(20.0),
      60,
      '第一支的縮圖帶要在轉檔期間就精抽成 20 格',
    );
    expect(_workDone, lessThan(2), reason: '縮圖帶精抽不等整批轉完');

    // 第一支 0.4 秒轉好、第二支要 1.6 秒（序列的）：第二支開轉＝第一支已落地
    await _until(t, () => _workArguments.length >= 2, 80, '第二支要開始轉');
    final work1 = _workArguments[0]['dest'] as String;
    final work2 = _workArguments[1]['dest'] as String;
    // 第一支落地後閒置 1.2 秒就換進合成，這時第二支還在轉（還是原檔）
    await _until(
      t,
      () => builds.any((b) => b[0] == work1 && b[1] == _p('second.mov')),
      60,
      '第一支落地就該換進合成，不等第二支：$builds',
    );
    _swallowMediaKit(t);
    // 工作檔換上（密關鍵幀）：縮圖帶從工作檔再精抽一次
    await _until(t, () => _framePaths.contains(work1), 60, '換上工作檔後要從工作檔重抽縮圖帶');
    // 整批做完：第二支也換上
    await _until(
      t,
      () => builds.any((b) => b[0] == work1 && b[1] == work2),
      80,
      '整批做完兩支都要是工作檔：$builds',
    );
    _swallowMediaKit(t);

    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await _settle(t, 10);
    // 離開後把還沒到期的計時器走完（轉檔完的顏色探針 2 秒、合成的清理 1.7 秒）
    await t.pump(const Duration(seconds: 5));
    _swallowMediaKit(t);
  });
}
