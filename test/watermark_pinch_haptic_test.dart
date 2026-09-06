// 守門：影片編輯頁兩指縮放浮水印文字時，觸覺回饋不能連發、文字不能
// 順手轉歪、畫面不能跳。
//
// 使用者回報「浮水印文字樣式放大縮小時螢幕會震動」。量出來的根因在
// _previewPinchMove 的旋轉吸附（舊 _snapAngle）：兩指縮放時手指連線的
// 角度自然會抖個三五度，舊碼每一格重判一次「轉超過 3 度才算旋轉」與
// 「離 15 度刻度 4 度內黏上去、超過就脫離」，抖在 3~5 度之間就是黏上
// （震一下、文字轉回 0）→ 脫離（文字轉到 5 度）→ 又黏上（又震）……
// 同一支測試在修之前量到：角度 3.5／5 度交替的 30 格捏合震 15 次、
// 隨機 ±6 度的 30 格震 5 次、捏完文字歪了 5~11 度。
//
// 第二個來源：選取路由的置中吸附起手就把「黏住」旗標清成 false，本來
// 就坐在中線上的文字素材，捏合第一格看到 x==0.5 就當「剛吸上去」震一下。
//
// 觸覺回饋走 flutter/platform 通道的 HapticFeedback.vibrate，這裡攔下來數
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/watermark_layer.dart';

Future<void> _tick(WidgetTester t, [int frames = 10, int ms = 40]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

void main() {
  const compCh = MethodChannel('markcut/comp');
  late List<String> haptics;

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1100, 2200);
    v.devicePixelRatio = 1.0;
    for (final ch in const [
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
    haptics = [];
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          return <String, dynamic>{
            'textureId': 1,
            'duration': 10.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': true,
          };
        case 'setXform':
          return true;
      }
      return null;
    });
    b.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add('${call.arguments}');
      }
      return null;
    });
  });

  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  /// 影片墊在 5~10 秒；播放頭 0 時畫面上是預設的浮水印文字（正中央）
  /// 跟一段文字素材（下方，x 正好在中線上）
  late TimelineModel tl;
  void seed(TimelineModel m) {
    tl = m;
    m.sources.add(
      MediaSource(
        path: '/v.mp4',
        name: 'v',
        kind: ClipKind.video,
        duration: 100,
        workPath: '/v.work.mp4',
      ),
    );
    m.clips.add(
      TimelineClip(
        id: m.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 5,
        track: 0,
      ),
    );
    m.sources.add(
      MediaSource(
        path: '',
        name: 't',
        kind: ClipKind.text,
        duration: 3600,
        textStyle: TextMark(text: '你好'),
      ),
    );
    m.clips.add(
      TimelineClip(
        id: m.nextId(),
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 8,
        offset: 0,
        track: 1,
        px: 0.5,
        py: 0.85,
      ),
    );
  }

  Map<String, int> rebuilt = {};
  void startCounting() {
    rebuilt = {};
    debugOnRebuildDirtyWidget = (e, _) {
      final k = e.widget.runtimeType.toString();
      rebuilt[k] = (rebuilt[k] ?? 0) + 1;
    };
  }

  void stopCounting() => debugOnRebuildDirtyWidget = null;
  int of(String k) => rebuilt[k] ?? 0;

  Future<WatermarkSettings> open(WidgetTester t) async {
    await t.pumpWidget(
      const MaterialApp(home: VideoEditorScreen(blank: true)),
    );
    await _tick(t, 5);
    VideoEditorScreen.debugTimeline!(seed);
    await _tick(t, 15);
    return t.widget<WatermarkLayer>(find.byType(WatermarkLayer).first).settings;
  }

  /// 兩指捏合 [steps] 格：兩指以 [c] 為中心、起手相距 [gap0]、每格拉開
  /// [perStep]；[angleDeg] 給每一格兩指連線相對水平的角度（起手是 0），
  /// [focalDx] 給中點的水平漂移。每一格都 pump 一次，跟真機一格一個
  /// 指針事件一樣
  Future<void> pinch(
    WidgetTester t,
    Offset c,
    int steps, {
    double Function(int i)? angleDeg,
    double Function(int i)? focalDx,
    double gap0 = 60,
    double perStep = 6,
    void Function()? eachStep,
  }) async {
    final a = await t.startGesture(c + Offset(-gap0 / 2, 0));
    final b = await t.startGesture(c + Offset(gap0 / 2, 0));
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < steps; i++) {
      final gap = gap0 + perStep * (i + 1);
      final ang = (angleDeg?.call(i) ?? 0) * math.pi / 180;
      final half = Offset(math.cos(ang), math.sin(ang)) * (gap / 2);
      final mid = c + Offset(focalDx?.call(i) ?? 0, 0);
      await a.moveTo(mid - half);
      await b.moveTo(mid + half);
      await t.pump(const Duration(milliseconds: 16));
      eachStep?.call();
    }
    await a.up();
    await b.up();
    await t.pump();
  }

  testWidgets('全域浮水印文字：兩指縮放 30 格（含手指自然抖動）不震、不轉、大小對', (t) async {
    final s = await open(t);
    final canvas = t.getRect(find.byType(AspectRatio).first);
    final c = canvas.center;
    // 點預設浮水印文字＝選取它（會切到浮水印分頁；分頁開著時手勢中
    // 每 150ms 節流整頁重建一次讓面板滑桿跟手，那是設計）
    await t.tapAt(c);
    await _tick(t, 20);
    expect(s.text.rotation, 0);

    // ---- 兩指沿水平線筆直張開：60px → 240px＝4 倍 ----
    var size0 = s.text.sizeFrac;
    haptics.clear();
    startCounting();
    var canvasMoved = false;
    await pinch(
      t,
      c,
      30,
      eachStep: () {
        if (t.getRect(find.byType(AspectRatio).first) != canvas) {
          canvasMoved = true;
        }
      },
    );
    stopCounting();
    expect(haptics, isEmpty, reason: '筆直縮放沒跨過任何刻度，不該震');
    expect(s.text.sizeFrac, closeTo(size0 * 4, 1e-9), reason: '4 倍');
    expect(s.text.rotation, 0);
    expect(canvasMoved, isFalse, reason: '縮放中畫布不能跳');
    expect(
      of('WatermarkLayer'),
      greaterThanOrEqualTo(30),
      reason: '預覽層每格都要重畫（文字真的跟著手變大）',
    );
    // 整頁重建的次數不在這裡守：浮水印分頁開著時它是牆鐘 150ms 節流
    //（機器慢就多幾次），「手勢中不每格整頁重建」由
    // video_editor_gesture_rebuild_test 守
    await _tick(t, 30);

    // ---- 手指角度抖在 3.5／5 度之間（修之前：30 格震 15 次、文字轉到 5 度）----
    size0 = s.text.sizeFrac;
    haptics.clear();
    await pinch(t, c, 30, angleDeg: (i) => i.isEven ? 3.5 : 5.0);
    expect(haptics, isEmpty, reason: '抖動不是旋轉：一次都不能震');
    expect(s.text.rotation, 0, reason: '文字不能被順手轉歪');
    expect(s.text.sizeFrac, closeTo(size0 * 4, 1e-9));
    await _tick(t, 30);

    // ---- 隨機 ±6 度（修之前：震 5 次、文字歪到 11 度）----
    // 先把大小縮回去，不然 4 倍會撞到 2.0 的上限
    s.text.sizeFrac = 0.1;
    await _tick(t, 5);
    size0 = s.text.sizeFrac;
    final rnd = math.Random(7);
    haptics.clear();
    await pinch(t, c, 30, angleDeg: (_) => rnd.nextDouble() * 12 - 6);
    expect(haptics, isEmpty);
    expect(s.text.rotation, 0);
    expect(s.text.sizeFrac, closeTo(size0 * 4, 1e-9));
    await _tick(t, 100);
  });

  testWidgets('真的兩指旋轉浮水印文字（0→90 度）：每跨一個 15 度刻度震一次、吸在 90', (t) async {
    final s = await open(t);
    final c = t.getRect(find.byType(AspectRatio).first).center;
    await t.tapAt(c);
    await _tick(t, 20);
    final size0 = s.text.sizeFrac;
    haptics.clear();
    // 兩指距離不變＝只轉不縮；每格 3 度
    await pinch(t, c, 30, perStep: 0, angleDeg: (i) => (i + 1) * 3.0);
    expect(haptics.length, 6, reason: '15、30、45、60、75、90 各震一次');
    expect(haptics.toSet(), {'HapticFeedbackType.selectionClick'});
    expect(s.text.rotation, closeTo(90, 1e-6));
    expect(s.text.sizeFrac, closeTo(size0, 1e-9), reason: '只轉不縮');
    await _tick(t, 100);
  });

  testWidgets('文字素材（走選取路由）本來就坐在中線上：捏合起手不震、只變大', (t) async {
    await open(t);
    final canvas = t.getRect(find.byType(AspectRatio).first);
    final clip = tl.clips[1];
    final p = Offset(
      canvas.left + canvas.width * clip.px,
      canvas.top + canvas.height * clip.py,
    );
    await t.tapAt(p);
    await _tick(t, 20);
    final s0 = clip.scale;
    haptics.clear();
    await pinch(t, p, 30);
    // 修之前這裡是 1：路由起手把「黏住」清成 false，第一格看到 x==0.5
    // 就當「剛吸上去」
    expect(haptics, isEmpty, reason: '本來就在中線上，沒有「吸上去」這回事');
    expect(clip.scale, closeTo(s0 * 4, 1e-9));
    expect(clip.px, 0.5);
    expect(clip.py, 0.85);
    await _tick(t, 100);
  });
}
