// 影片編輯頁 widget 測試的共用件：假的原生外掛通道、等待、從時間軸
// 元件讀回狀態、假的合成播放器通道。各支迴歸測試自己組時間軸，這裡
// 只放大家都一樣的那些行（跟 play_to_end_last_frame_test／
// video_editor_overlap_test 同一套做法）。
//
// 檔名不帶 _test：不是測試，flutter test 不會跑它
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:markcut/models/timeline.dart';
import 'package:markcut/widgets/timeline_editor.dart';

/// 大一點的直式畫面（1100×2200、dpr 1）：時間軸的片段才夠寬，把手才
/// 點得到；跟既有的編輯頁測試同一組數字
void bigPhoneView(TestWidgetsFlutterBinding b) {
  final v = b.platformDispatcher.views.first;
  v.physicalSize = const Size(1100, 2200);
  v.devicePixelRatio = 1.0;
}

/// 測試環境沒有這些原生外掛，擋掉不然頁面一開就丟例外。
/// [tempDir] 給了的話 path_provider 回它——getTemporaryDirectory 收到
/// null 會丟 MissingPlatformDirectoryException
void mockEditorPlugins(TestWidgetsFlutterBinding b, {Directory? tempDir}) {
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
    (_) async => tempDir?.path,
  );
  // FFmpeg 的事件通道：不擋的話光是訂閱就會丟出沒人接的 MissingPluginException
  b.defaultBinaryMessenger.setMockStreamHandler(
    const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
    MockStreamHandler.inline(onListen: (_, _) {}),
  );
  b.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('flutter.arthenica.com/ffmpeg_kit'),
    (_) async => null,
  );
}

/// 編輯頁包進 MaterialApp。水波紋改用 InkRipple：Material 3 在 Android
///（測試主機的預設平台）用 InkSparkle，它要載 shaders/ink_sparkle.frag，
/// --no-test-assets 底下沒有這個資產，第一次點按鈕就丟一個沒人接的例外
/// 把整支測試判紅（同一個 isolate 只丟一次，所以同檔第二支反而會過）
Widget editorApp(Widget home) => MaterialApp(
  theme: ThemeData(splashFactory: InkRipple.splashFactory),
  home: home,
);

/// 真時間等一下再畫一格，重複 [n] 次：讀檔、原生通道回話這類真的非同步
/// 工作要靠它跑完
Future<void> settle(WidgetTester t, [int n = 25]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 一直等到 [cond] 成立（最多 [maxMs] 真時間），沒等到直接紅
Future<void> waitUntil(
  WidgetTester t,
  bool Function() cond, {
  int maxMs = 10000,
  String? reason,
}) async {
  final sw = Stopwatch()..start();
  while (!cond() && sw.elapsedMilliseconds < maxMs) {
    await settle(t, 1);
  }
  expect(cond(), isTrue, reason: reason);
}

/// 假時間畫 [frames] 格、每格 [ms] 毫秒（播放時鐘、計時器都跟著走）
Future<void> tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

TimelineEditor editorOf(WidgetTester t) =>
    t.widget<TimelineEditor>(find.byType(TimelineEditor));

TimelineModel modelOf(WidgetTester t) => editorOf(t).timeline;

TimelineClip clipOf(WidgetTester t, int id) =>
    modelOf(t).clips.firstWhere((c) => c.id == id);

double playheadOf(WidgetTester t) => editorOf(t).playhead.value;

bool isPlaying() => find.byIcon(Icons.pause_rounded).evaluate().isNotEmpty;

/// 時間軸上某個片段的方塊
Finder clipBlock(int id) => find.byKey(ValueKey('clip$id'));

/// 選取的片段兩端各有一顆把手（drag_indicator 圖示），拿左邊或右邊那顆
Finder handleOf(WidgetTester t, int clipId, {required bool left}) {
  final icons = find.descendant(
    of: clipBlock(clipId),
    matching: find.byIcon(Icons.drag_indicator),
  );
  expect(icons, findsNWidgets(2), reason: '選取的片段要有兩顆把手');
  final a = t.getCenter(icons.at(0));
  final b = t.getCenter(icons.at(1));
  final wantLeft = a.dx < b.dx ? icons.at(0) : icons.at(1);
  final wantRight = a.dx < b.dx ? icons.at(1) : icons.at(0);
  return left ? wantLeft : wantRight;
}

/// 設定表裡標籤是 [label] 的那條滑桿（sliderRow：標籤與 Slider 同一個 Row）
Finder sliderLabelled(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
  matching: find.byType(Slider),
);

Finder undoButton() => find.ancestor(
  of: find.byTooltip('上一步'),
  matching: find.byType(IconButton),
);

Finder redoButton() => find.ancestor(
  of: find.byTooltip('重做'),
  matching: find.byType(IconButton),
);

bool undoEnabled(WidgetTester t) =>
    t.widget<IconButton>(undoButton()).onPressed != null;

bool redoEnabled(WidgetTester t) =>
    t.widget<IconButton>(redoButton()).onPressed != null;

/// 一張純色 PNG（[size]×[size]）：要「兩張看得出不一樣」的圖時用
Uint8List solidPng(int r, int g, int b, {int size = 8}) {
  final im = img.Image(width: size, height: size);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(im));
}

/// 假的原生合成播放器（markcut/comp）。play 之後時鐘跟著測試的假時間走
///（每 33ms 前進 33ms，跟編輯器的 ticker 同步）；pause 停在 [stopAtMs]
///（給了的話）；[capAtEnd]＝position 到了合成結尾就不再前進——真的
/// AVPlayer 播到 item 尾端就是這樣停住的，尾巴專案（時間軸比合成長）
/// 靠這個演
class FakeComp {
  FakeComp(this.binding);

  final TestWidgetsFlutterBinding binding;
  static const channel = MethodChannel('markcut/comp');

  double duration = 5.0;
  int? stopAtMs;
  bool capAtEnd = false;
  int nativeMs = 0;
  int builds = 0;
  final seeks = <Map<Object?, Object?>>[];
  Timer? _clock;

  void install() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          builds++;
          return <String, dynamic>{
            'textureId': 1,
            'duration': duration,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
        case 'play':
          _clock?.cancel();
          _clock = Timer.periodic(
            const Duration(milliseconds: 33),
            (_) => nativeMs += 33,
          );
          return '乾淨';
        case 'pause':
          _clock?.cancel();
          _clock = null;
          if (stopAtMs != null) nativeMs = stopAtMs!;
          return null;
        case 'position':
          return capAtEnd
              ? math.min(nativeMs, (duration * 1000).round())
              : nativeMs;
        case 'seek':
          final a = Map<Object?, Object?>.from(call.arguments as Map);
          seeks.add(a);
          nativeMs = ((a['sec'] as num) * 1000).round();
          return a['awaitCompletion'] == true ? true : null;
        case 'setHiddenImageTracks':
          return true;
      }
      return null;
    });
  }

  void uninstall() {
    _clock?.cancel();
    _clock = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  }
}
