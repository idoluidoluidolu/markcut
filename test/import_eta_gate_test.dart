// 匯入遮罩上的「約還要多久」（使用者要求：匯入也要有預估剩下時間）。
//
// 用真的編輯頁跑一趟兩支素材的匯入，假的原生端讓第一支轉 0.4 秒、
// 第二支轉 1.6 秒。守兩件事：
// 1. 還沒量到倍速時是「估算中…」，量到之後變成真的倒數；
// 2. X／N 會前進——以前這個數字整段匯入停在 1（實機回報）。
//
// 這裡不模擬轉檔進度回報（那是原生端每 200ms 送一次的事，
// 算術本身在 test/import_eta_test.dart 守）：第二支的讀數靠的是
// 「第一支轉完」這個樣本，跟實機上第二支之後的情形一樣
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/export_eta.dart';
import 'package:markcut/services/media_prep.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';
import 'package:markcut/widgets/prep_gate_view.dart';

late Directory _dir;
Completer<void>? _holdWork;
int _workStarted = 0;

/// 每支素材：多長、假的原生端要轉多久
const _videos = <String, ({double dur, int workMs})>{
  'first.mov': (dur: 20.0, workMs: 400),
  'second.mov': (dur: 40.0, workMs: 1600),
};

String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

/// 真的讓時間過去（假的原生端用 Future.delayed 模擬轉檔），
/// 同時把 widget 的時鐘往前推（每秒重算讀數的計時器要走）
Future<void> _settle(WidgetTester t, int steps) async {
  for (var i = 0; i < steps; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 測試主機沒有 libmpv：遮罩收掉之後編輯器要建預覽播放器就會丟這個。
/// 跟這一頁要守的東西無關，吞掉——但只吞這一種
void _swallowMediaKit(WidgetTester t) {
  for (;;) {
    final e = t.takeException();
    if (e == null) return;
    expect('$e', contains('MediaKit'), reason: '只有「測試主機沒有 libmpv」可以吞');
  }
}

/// 遮罩上那一行小字（沒有就回 null）
String? _gateLine(WidgetTester t) {
  for (final w in t.widgetList<Text>(find.byType(Text))) {
    final s = w.data;
    if (s == null) continue;
    if (s.contains('支 ·') || s.contains('準備中') || s.contains('組畫面')) {
      return s;
    }
  }
  return null;
}

void main() {
  setUpAll(() {
    _dir = Directory.systemTemp.createTempSync('markcut_import_eta_');
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
    // 假的轉檔端：素材是 HEVC SDR（規格不合＝一定要轉），
    // toWorkFile 花掉這支素材該花的時間才回
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
              'sdr709': true, // SDR：走工作檔那條，不用問 hasHDR
              'durSec': v?.dur ?? 5.0,
            };
          case 'toWorkFile':
            _workStarted++;
            await _holdWork?.future;
            final a = call.arguments as Map<Object?, Object?>;
            final src = a['src'] as String;
            final dest = a['dest'] as String;
            final v = _videos[src.split(Platform.pathSeparator).last];
            await Future<void>.delayed(
              Duration(milliseconds: v?.workMs ?? 100),
            );
            await File(dest).writeAsString('work');
            return dest;
        }
        return null;
      },
    );
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    MediaPrep.resetProbeCacheForTest();
    WorkFiles.resetForTest();
    ImportEta.resetLearnedTail();
    _holdWork = null;
    _workStarted = 0;
  });

  tearDownAll(() {
    WorkFiles.supportDirOverride = null;
    WorkFiles.resetForTest();
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('預設匯入：轉檔仍未完成時已可拖曳時間軸', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    _holdWork = Completer<void>();
    final oldLayer = Diag.playerLayer.value;
    Diag.playerLayer.value = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('markcut/comp'), (
      call,
    ) async {
      if (call.method == 'available') return true;
      if (call.method == 'build') {
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
      if (!_holdWork!.isCompleted) _holdWork!.complete();
    });
    await t.pumpWidget(
      MaterialApp(
        home: VideoEditorScreen(
          videoPaths: [_p('first.mov'), _p('second.mov')],
        ),
      ),
    );
    await _settle(t, 40);
    _swallowMediaKit(t);
    expect(_workStarted, 1, reason: '背景轉檔已開始，而且仍被測試卡住');
    expect(find.byType(PrepGateView), findsNothing);
    expect(find.byType(TimelineEditor), findsOneWidget);
    await t.drag(find.byType(TimelineEditor), const Offset(-150, 0));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(TimelineEditor), findsOneWidget);
    expect(_holdWork!.isCompleted, false);
    // Leave with a decode still in flight. Its completion must not touch UI.
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    _holdWork!.complete();
    await _settle(t, 25);
    await t.pump(const Duration(seconds: 5));
    _swallowMediaKit(t);
  });

  testWidgets('遮罩：估算中… → 量到倍速就變成倒數，X／N 跟著前進', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await t.pumpWidget(
      MaterialApp(
        home: VideoEditorScreen(
          videoPaths: [_p('first.mov'), _p('second.mov')],
          waitForPreparation: true,
        ),
      ),
    );

    // 整趟遮罩期間看到過的每一行字
    final seen = <String>[];
    for (var i = 0; i < 120; i++) {
      await _settle(t, 1);
      _swallowMediaKit(t);
      final line = _gateLine(t);
      if (line == null) {
        if (seen.isNotEmpty) break; // 遮罩收掉了
        continue;
      }
      if (seen.isEmpty || seen.last != line) seen.add(line);
    }

    expect(
      seen.any((s) => s == '第 1 / 2 支 · 估算中…'),
      isTrue,
      reason: '第一支還沒轉完、也還沒有進度樣本：只能說估算中（看到的是 $seen）',
    );
    expect(
      seen.any((s) => RegExp(r'^第 2 / 2 支 · 約還要 \d+ 秒$').hasMatch(s)),
      isTrue,
      reason: '第一支轉完就有倍速了，第二支要給真的倒數（看到的是 $seen）',
    );
    // 收尾那一段也要有讀數，不能停在「快好了」不動
    expect(
      seen.any((s) => s.startsWith('正在組畫面')),
      isTrue,
      reason: '組合成也是遮罩的一段（看到的是 $seen）',
    );

    // 沒有停在 1／2：兩支都輪到過
    expect(seen.any((s) => s.startsWith('第 1 / 2 支')), isTrue);
    expect(seen.any((s) => s.startsWith('第 2 / 2 支')), isTrue);

    // 收尾：讓提示條、草稿併批、延遲刷新那些計時器走完，
    // 不然測試框架會抱怨「widget 樹拆了還有 Timer 掛著」
    for (var i = 0; i < 10; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump(const Duration(seconds: 1));
      _swallowMediaKit(t);
    }
    // 自己把編輯器卸掉：拆的時候會去 dispose 預覽播放器，而測試主機
    // 沒有 libmpv（同上）。留給框架在測試結束後拆的話那個例外就吞不到了
    await t.pumpWidget(const MaterialApp(home: SizedBox()));
    _swallowMediaKit(t);
    await t.pump(const Duration(seconds: 1));
    _swallowMediaKit(t);
  });
}
