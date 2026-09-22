// 多選匯入閃退（2026-09-23 新眼睛）：代理／工作檔一落地就整顆重組合成，
// 原生端新舊兩顆播放器同時活到新畫面上屏；以前這時下一支 4K 轉檔已經
// 開工（閒置 600ms 就開、重組要 1.2 秒後才做），兩顆預覽管線＋轉檔器的
// 解碼器／編碼器＋縮圖解碼器疊在一起，而全 App 只有轉檔器有記憶體閘門。
//
// 這裡守三件事：
//   1. 重組一律落在兩支轉檔之間（任何一支轉檔進行中都不組）
//   2. 整批轉檔期間不從 4K 原檔精抽縮圖帶（代理落地才從代理抽）
//   3. 重組失敗時保留舊畫面、稍後重試，不退回逐片段播放器
//      （HDR 的 previewPath 是 4K 原檔，N 支疊在 0 秒＝N 顆 4K 解碼器）
//
// 假的原生端跟 prep_swap_per_clip_test 同一套（SDR 素材走工作檔）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/export_eta.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';

import 'comp_visible.dart';
import 'editor_harness.dart' show solidPng;

late Directory _dir;

/// 依序發生的事：work-start:名 / work-end:名 / build:路徑,路徑 / frame:名 /
/// dispose
final _log = <String>[];

/// 第幾次 build（從 1 起算）要回原生端的「組不起來」
final _failBuilds = <int>{};
var _builds = 0;

const _videos = <String, ({double dur, int workMs})>{
  'first.mov': (dur: 20.0, workMs: 400),
  'second.mov': (dur: 40.0, workMs: 1600),
};

String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';
String _base(String path) => path.split(Platform.pathSeparator).last;

Future<void> _settle(WidgetTester t, int steps) async {
  for (var i = 0; i < steps; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _until(
  WidgetTester t,
  bool Function() ok,
  int steps,
  String why,
) async {
  for (var i = 0; i < steps && !ok(); i++) {
    await _settle(t, 1);
  }
  expect(ok(), isTrue, reason: '$why\n$_log');
}

void _swallowMediaKit(WidgetTester t) {
  for (;;) {
    final e = t.takeException();
    if (e == null) return;
    expect('$e', contains('MediaKit'), reason: '只有「測試主機沒有 libmpv」可以吞');
  }
}

/// 某支轉檔進行中（work-start 之後、work-end 之前）有沒有發生 [what]
List<String> _duringWork(bool Function(String event) what) {
  final open = <String>{};
  final hits = <String>[];
  for (final e in _log) {
    if (e.startsWith('work-start:')) open.add(e.substring(11));
    if (e.startsWith('work-end:')) open.remove(e.substring(9));
    if (open.isNotEmpty && what(e)) hits.add('$e（轉檔中：$open）');
  }
  return hits;
}

int _firstIndex(bool Function(String event) what) => _log.indexWhere(what);

void main() {
  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('markcut_rebuild_gap_');
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
            final v = _videos[_base(call.arguments as String)];
            return <String, dynamic>{
              'w': 3840,
              'h': 2160,
              'codec': 'hvc1',
              'rotated': false,
              'sdr709': true,
              'durSec': v?.dur ?? 5.0,
            };
          case 'toWorkFile':
            final a = call.arguments as Map<Object?, Object?>;
            final name = _base(a['src'] as String);
            final dest = a['dest'] as String;
            _log.add('work-start:$name');
            await Future<void>.delayed(
              Duration(milliseconds: _videos[name]?.workMs ?? 100),
            );
            await File(dest).writeAsString('work');
            _log.add('work-end:$name');
            return dest;
        }
        return null;
      },
    );
    final frame = solidPng(0, 255, 0);
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('markcut/frames'),
      (call) async {
        if (call.method != 'frameAt') return null;
        final a = Map<Object?, Object?>.from(call.arguments as Map);
        _log.add('frame:${_base(a['path'] as String)}');
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
    _log.clear();
    _failBuilds.clear();
    _builds = 0;
  });

  tearDownAll(() {
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 假的合成通道：組建照記、指定的那幾次回「組不起來」；組好的那幾次
  /// 120ms 後由「原生端」回報 compVisible（新畫面上屏、舊播放器收掉）
  void mockComp(WidgetTester t) {
    final oldLayer = Diag.playerLayer.value;
    Diag.playerLayer.value = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('markcut/comp'), (
      call,
    ) async {
      if (call.method == 'available') return true;
      if (call.method == 'dispose') _log.add('dispose');
      if (call.method != 'build') return null;
      _builds++;
      final clips = (call.arguments as Map)['clips'] as List;
      _log.add(
        'build:${[for (final c in clips) _base((c as Map)['path'] as String)].join(',')}',
      );
      if (_failBuilds.contains(_builds)) {
        return <String, dynamic>{'error': '假的原生端：組不起來'};
      }
      scheduleCompVisible();
      return <String, dynamic>{
        'textureId': 1,
        'duration': 60.0,
        'width': 1920.0,
        'height': 1080.0,
      };
    });
    addTearDown(() {
      Diag.playerLayer.value = oldLayer;
      messenger.setMockMethodCallHandler(
        const MethodChannel('markcut/comp'),
        null,
      );
    });
  }

  Future<void> leave(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    await _settle(t, 10);
    await t.pump(const Duration(seconds: 10));
    _swallowMediaKit(t);
  }

  bool workBuild(String event) =>
      event.startsWith('build:') && event.contains('.mp4');

  testWidgets('落地的重組在兩支轉檔之間做完；轉檔期間不從原檔精抽縮圖帶', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    mockComp(t);
    await t.pumpWidget(
      MaterialApp(
        home: VideoEditorScreen(
          videoPaths: [_p('first.mov'), _p('second.mov')],
        ),
      ),
    );
    await _until(t, () => _builds > 0, 60, '首合成要組起來');
    _swallowMediaKit(t);
    await _until(
      t,
      () => _log.contains('work-end:second.mov'),
      200,
      '兩支都要轉完',
    );
    // 整批做完的那次重組（兩支都是工作檔）
    await _until(
      t,
      () => _log.any((e) => e.startsWith('build:') && !e.contains('.mov')),
      120,
      '整批做完要換成兩支都是工作檔',
    );
    _swallowMediaKit(t);

    expect(
      _duringWork((e) => e.startsWith('build:')),
      isEmpty,
      reason: '任何一支轉檔進行中都不能組合成',
    );
    final landed = _firstIndex(workBuild);
    final secondStarts = _log.indexOf('work-start:second.mov');
    expect(landed, greaterThanOrEqualTo(0), reason: '第一支落地要換進合成：$_log');
    expect(
      landed,
      lessThan(secondStarts),
      reason: '第一支落地的重組要在第二支開轉之前做完（秒進照舊）：$_log',
    );
    expect(
      _duringWork((e) => e == 'frame:second.mov'),
      isEmpty,
      reason: '整批轉檔期間不從 4K 原檔精抽縮圖帶',
    );
    expect(
      _log.where((e) => e.startsWith('frame:') && e.endsWith('.mp4')),
      isNotEmpty,
      reason: '落地的工作檔要拿來抽縮圖帶',
    );
    await leave(t);
  });

  testWidgets('重組失敗保留目前畫面、在下一支開轉前重試，不退回逐片段播放器', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // 第 1 次＝進場；第 2 次＝第一支落地的重組 → 組不起來
    _failBuilds.add(2);
    mockComp(t);
    await t.pumpWidget(
      MaterialApp(
        home: VideoEditorScreen(
          videoPaths: [_p('first.mov'), _p('second.mov')],
        ),
      ),
    );
    await _until(t, () => _builds > 0, 60, '首合成要組起來');
    _swallowMediaKit(t);
    await _until(t, () => _builds >= 3, 200, '組不起來之後要自己重試');
    _swallowMediaKit(t);
    final failed = _log.indexWhere(workBuild);
    final retried = _log.indexWhere(workBuild, failed + 1);
    expect(retried, greaterThan(failed), reason: '重試還是那一版（第一支工作檔）：$_log');
    expect(
      _log.sublist(failed, retried),
      isNot(contains('dispose')),
      reason: '組不起來時舊畫面要留著，不能先收掉再退回逐片段播放器',
    );
    await _until(
      t,
      () => _log.contains('work-end:second.mov'),
      200,
      '第二支照樣要轉完',
    );
    _swallowMediaKit(t);
    expect(
      retried,
      lessThan(_log.indexOf('work-start:second.mov')),
      reason: '重試也落在兩支轉檔之間：$_log',
    );
    expect(
      _duringWork((e) => e.startsWith('build:')),
      isEmpty,
      reason: '失敗與重試都不能疊在轉檔上',
    );
    await leave(t);
  });
}
