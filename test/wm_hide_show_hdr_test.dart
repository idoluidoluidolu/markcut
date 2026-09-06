// 迴歸守門：使用者回報「浮水印隱藏再打開，原本白色變成灰色」（HLG 素材）。
//
// HDR 預覽的浮水印是烘進合成、由原生 CI 合成器畫的（線性光提亮、
// 底圖夾白，白才是白）；Flutter 那份只留 1% 透明度給觸控。「隱藏」以前
// 會把浮水印從合成的結構指紋（_compSig 的 ovNeed）拿掉，於是隱藏期間
// 任何一次合成重建（存草稿、HDR 代理轉好、切分頁……）都組出「沒掛
// 合成器、不收即時清單（wmLive=false）」的合成；「打開」只走 setOverlays
// 即時通道，被那份合成拒收、又沒有人排重建——浮水印只好由 Flutter 以
// SDR 基準白畫在 HDR 畫面上，看起來就是灰的。
//
// 這裡用假的原生端把 needsCI／wmLive／setOverlays 的收件規則照抄
//（AppDelegate.swift：沒疊加物又沒 ovLive＝不掛合成器；wmLive 才收
// 清單），釘住兩件事：
//   1. HDR：隱藏→（合成重建）→打開 之後，浮水印跟「從來沒隱藏過」走同
//      一條路——原生清單非空、Flutter 版 1% 透明；而且隱藏／打開本身
//      都不重組合成（即時清單那條路，不閃）
//   2. SDR：一個位元都不變——浮水印全程由 Flutter 畫（不透明度 1）、
//      不送即時清單、build 不要求掛合成器
//
// 整段跑在 runAsync 裡：烘浮水印 PNG（ui.Image.toByteData）要引擎那頭
// 回話，假時鐘的測試區裡永遠等不到；所以計時器全是真時間，等待用真等
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/comp_player.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/timeline_editor.dart';
import 'package:markcut/widgets/watermark_layer.dart';

/// 真等 [ms] 毫秒再畫一格（runAsync 裡計時器是真時鐘）
Future<void> _wait(WidgetTester t, int ms) async {
  await Future<void>.delayed(Duration(milliseconds: ms));
  await t.pump();
}

/// 一直等到 [cond] 成立（最多 [maxMs]），期間每 25ms 畫一格
Future<void> _waitUntil(
  WidgetTester t,
  bool Function() cond, {
  int maxMs = 10000,
}) async {
  final sw = Stopwatch()..start();
  while (!cond() && sw.elapsedMilliseconds < maxMs) {
    await _wait(t, 25);
  }
}

/// 畫面上 Flutter 版浮水印的不透明度：null＝根本沒畫（隱藏中）；
/// 0.01＝原生烘好的在畫、Flutter 版只留觸控；1＝Flutter 版就是畫面上那份
double? _flutterWmOpacity(WidgetTester t) {
  if (find.byType(WatermarkLayer).evaluate().isEmpty) return null;
  final wraps = t
      .widgetList<Opacity>(find.byType(Opacity))
      .where((o) => o.child is WatermarkLayer)
      .toList();
  expect(wraps, hasLength(1), reason: '全域浮水印圖層只該有一份');
  return wraps.single.opacity;
}

void main() {
  const compCh = MethodChannel('markcut/comp');
  const exportCh = MethodChannel('markcut/export');

  /// 假原生端的狀態（照 AppDelegate.swift 的規則）
  late List<Map<Object?, Object?>> builds;
  late List<List<Object?>> overlaySets;
  late bool nativeWmLive;
  late int nativeOverlayCount;
  late int rejects;
  late bool sourceIsHdr;

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1100, 2200);
    v.devicePixelRatio = 1.0;
    for (final ch in const [
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/wakelock',
      'markcut/prep',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 測試環境沒有真的原生 UiKitView：合成畫面走 Texture
    Diag.playerLayer.value = false;
    builds = [];
    overlaySets = [];
    nativeWmLive = false;
    nativeOverlayCount = 0;
    rejects = 0;
    sourceIsHdr = true;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(exportCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'hasHDR':
          return sourceIsHdr;
      }
      return null;
    });
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          final a = Map<Object?, Object?>.from(call.arguments as Map);
          builds.add(a);
          final hdrOut = a['hdrOut'] == true;
          final clips = (a['clips'] as List?) ?? const [];
          final anyHDR = clips.any((c) => (c as Map)['hdr'] == true);
          final overlays = (a['overlays'] as List?) ?? const [];
          final stills = (a['stills'] as List?) ?? const [];
          final ovLive = a['ovLive'] == true;
          // AppDelegate.swift 的 needsCI（這裡的時間軸沒馬賽克／裁切／
          // 旋轉／透明度：剩烘進去的圖片跟 HDR 那兩條）
          final needsCI =
              stills.isNotEmpty ||
              (anyHDR && !hdrOut) ||
              (hdrOut && anyHDR && (overlays.isNotEmpty || ovLive));
          // wmLive：HDR 預覽且掛了合成器才收即時清單；組建當下的
          // 清單就是畫面上那份（setPreviewOverlays）
          nativeWmLive = hdrOut && anyHDR && needsCI;
          if (nativeWmLive) nativeOverlayCount = overlays.length;
          return <String, dynamic>{
            'textureId': 1,
            'duration': 5.0,
            'width': 1080.0,
            'height': 1920.0,
            'ci': needsCI,
            'hdr': anyHDR,
            'wmLive': nativeWmLive,
          };
        case 'setOverlays':
          // guard let p = self.comp, p.wmLive ... else { result(false) }
          if (!nativeWmLive) {
            rejects++;
            return false;
          }
          final list = List<Object?>.from(
            (call.arguments as Map)['overlays'] as List,
          );
          overlaySets.add(list);
          nativeOverlayCount = list.length;
          return true;
        case 'setXform':
        case 'setOvXform':
        case 'setHiddenImageTracks':
          return true;
        case 'mbuild':
        case 'mready':
        case 'mplay':
          return false;
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(compCh, null);
    b.defaultBinaryMessenger.setMockMethodCallHandler(exportCh, null);
    CompPlayer.debugHdrProbe = null;
    CompPlayer.debugClearHdrStills();
  });

  /// 一支影片 0~5 秒。HDR 版給 workHdrPath（HDR 判定免探測、代理免轉），
  /// SDR 版只給 workPath——都不碰檔案系統。
  /// [withImage]：再壓一張圖片在影片之上（軌 1，0~3 秒）——被浮水印
  /// 蓋到，HDR 預覽會把它烘進合成（CompPlayer.bakedImageIds 的 underWm）
  void seed(TimelineModel tl, {required bool hdr, bool withImage = false}) {
    tl.sources.add(
      MediaSource(
        path: hdr ? '/a.mov' : '/a.mp4',
        name: 'a',
        kind: ClipKind.video,
        duration: 100,
        workPath: '/a.work.mp4',
        workHdrPath: hdr ? '/a.hlg.mp4' : null,
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 0,
      ),
    );
    if (!withImage) return;
    tl.sources.add(
      MediaSource(
        path: '/p.png',
        name: 'p',
        kind: ClipKind.image,
        duration: 3600,
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 3,
        offset: 0,
        track: 1,
      ),
    );
  }

  /// 進場：空白專案 → 塞時間軸 → 到匯出頁一趟（HDR 判定在那裡出爐，
  /// 預設「保留 HDR」＝預覽走 HDR）→ 回剪輯頁，等合成組好
  Future<void> enter(
    WidgetTester t, {
    required bool hdr,
    bool withImage = false,
  }) async {
    sourceIsHdr = hdr;
    await t.pumpWidget(const MaterialApp(home: VideoEditorScreen(blank: true)));
    await _wait(t, 100);
    VideoEditorScreen.debugTimeline!(
      (tl) => seed(tl, hdr: hdr, withImage: withImage),
    );
    await _wait(t, 50);
    await t.tap(find.text('匯出'));
    await _wait(t, 50);
    await t.tap(find.text('剪輯'));
    await _waitUntil(
      t,
      () => builds.isNotEmpty && (builds.last['hdrOut'] == true) == hdr,
    );
    // 併批重建（350ms）＋ 組建：全部落地再往下
    await _wait(t, 600);
    // 原生回報新畫面上檔（真機由 compVisible 通知）
    CompPlayer.onCompVisible?.call();
    await t.pump();
    if (hdr) {
      // 合成上檔後指紋裡的畫框比例才定案，同步會把同一份內容再送一次
      //（快路→停穩補全解析 PNG）：等它送完，之後的清單變化才是這裡的動作
      await _waitUntil(
        t,
        () =>
            overlaySets.isNotEmpty &&
            overlaySets.last.every((m) => (m as Map).containsKey('png')),
      );
    }
    await _wait(t, 300);
  }

  void toggleWm(WidgetTester t) {
    t.widget<TimelineEditor>(find.byType(TimelineEditor)).onToggleWmVisible!();
  }

  /// 收尾：畫面拆掉（計時器在 dispose 收），不留真時鐘的計時器
  Future<void> leave(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await _wait(t, 50);
  }

  testWidgets('HDR：隱藏→合成重建→打開，浮水印回到原生那條路（不是 Flutter 的灰白）', (t) async {
    await t.runAsync(() async {
      await enter(t, hdr: true);
      expect(builds.last['hdrOut'], isTrue, reason: '進場後預覽走 HDR');
      expect(
        builds.last['overlays'],
        isNotEmpty,
        reason: '從沒隱藏過：浮水印在組建當下就烘進合成',
      );
      expect(nativeWmLive, isTrue);
      expect(nativeOverlayCount, greaterThan(0));
      expect(
        _flutterWmOpacity(t),
        0.01,
        reason: '從沒隱藏過：原生在畫，Flutter 版只留 1% 給觸控',
      );
      final buildsAtStart = builds.length;

      // ---- 隱藏：即時清單清空，不重組合成 ----
      final setsBeforeHide = overlaySets.length;
      toggleWm(t);
      await _waitUntil(t, () => overlaySets.length > setsBeforeHide);
      expect(overlaySets.last, isEmpty, reason: '隱藏＝送空清單');
      expect(nativeOverlayCount, 0);
      expect(_flutterWmOpacity(t), isNull, reason: '隱藏中 Flutter 版也不畫');
      await _wait(t, 600);
      expect(builds.length, buildsAtStart, reason: '隱藏不重組合成');

      // ---- 隱藏期間別的編輯讓合成重建（存草稿、代理轉好、切分頁都會）----
      VideoEditorScreen.debugTimeline!((tl) => tl.clips.first.trimEnd = 4.5);
      await _waitUntil(t, () => builds.length > buildsAtStart);
      await _wait(t, 100);
      expect(builds.length, buildsAtStart + 1);
      expect(builds.last['overlays'], isEmpty, reason: '隱藏中重建：組建當下沒有東西要畫');
      expect(
        builds.last['ovLive'],
        isTrue,
        reason: '但浮水印隨時會被打開：合成器要留著、即時清單要收得下',
      );
      expect(nativeWmLive, isTrue, reason: '隱藏中重建的合成也收即時清單');
      CompPlayer.onCompVisible?.call();
      await t.pump();
      expect(_flutterWmOpacity(t), isNull);
      final buildsBeforeShow = builds.length;

      // ---- 打開：走即時清單，原生畫、Flutter 版藏，跟從沒隱藏過一樣 ----
      overlaySets.clear();
      toggleWm(t);
      await _waitUntil(t, () => overlaySets.isNotEmpty || rejects > 0);
      expect(rejects, 0, reason: '打開送的清單不能被拒收');
      expect(overlaySets, isNotEmpty, reason: '打開＝送回清單');
      expect(overlaySets.last, isNotEmpty);
      expect(nativeOverlayCount, greaterThan(0));
      expect(
        _flutterWmOpacity(t),
        0.01,
        reason: '打開後：原生在畫、Flutter 版 1%（不是 SDR 基準白蓋在 HDR 上）',
      );
      // 停穩後補一版全解析（PNG），畫面上那份跟從沒隱藏過的同一種載體
      await _waitUntil(
        t,
        () => overlaySets.last.every((m) => (m as Map).containsKey('png')),
      );
      expect(
        overlaySets.last.every((m) => (m as Map).containsKey('png')),
        isTrue,
        reason: '最後上屏的是全解析 PNG，跟組建當下烘進去的那份同一種',
      );
      await _wait(t, 600);
      expect(builds.length, buildsBeforeShow, reason: '打開也不重組合成（不閃）');
      expect(_flutterWmOpacity(t), 0.01);
      expect(rejects, 0);

      await leave(t);
    });
  });

  testWidgets('SDR：隱藏→合成重建→打開，浮水印照舊全由 Flutter 畫、不碰即時清單', (t) async {
    await t.runAsync(() async {
      await enter(t, hdr: false);
      expect(builds.last['hdrOut'], isFalse);
      expect(builds.last['ovLive'], isNot(isTrue), reason: 'SDR 不要求掛合成器');
      expect(nativeWmLive, isFalse);
      expect(_flutterWmOpacity(t), 1.0, reason: 'SDR：Flutter 版就是畫面上那份');
      final buildsAtStart = builds.length;

      toggleWm(t);
      await _wait(t, 600);
      expect(_flutterWmOpacity(t), isNull);
      expect(overlaySets, isEmpty, reason: 'SDR 沒有收件方，不送即時清單');
      expect(builds.length, buildsAtStart, reason: '隱藏不重組合成');

      VideoEditorScreen.debugTimeline!((tl) => tl.clips.first.trimEnd = 4.5);
      await _waitUntil(t, () => builds.length > buildsAtStart);
      await _wait(t, 100);
      expect(builds.last['overlays'], isEmpty);
      expect(builds.last['ovLive'], isNot(isTrue), reason: 'SDR 不要求掛合成器');
      expect(nativeWmLive, isFalse);
      final buildsBeforeShow = builds.length;

      toggleWm(t);
      await _wait(t, 1200);
      expect(_flutterWmOpacity(t), 1.0, reason: '打開後跟從沒隱藏過一樣');
      expect(overlaySets, isEmpty);
      expect(rejects, 0, reason: 'SDR 根本不該去敲原生');
      expect(builds.length, buildsBeforeShow, reason: '打開也不重組合成');

      await leave(t);
    });
  });

  testWidgets('HDR＋被浮水印蓋到的圖片：隱藏／打開都不重組，圖片一直烘在合成裡', (t) async {
    await t.runAsync(() async {
      // 圖片不是 HDR 照片（不碰原生探測）
      CompPlayer.debugHdrProbe = (_) async => false;
      await enter(t, hdr: true, withImage: true);
      expect(
        builds.last['stills'],
        isNotEmpty,
        reason: '被浮水印蓋到的圖片烘進合成，浮水印才疊得上去（z 序）',
      );
      expect(builds.last['overlays'], isNotEmpty);
      expect(nativeWmLive, isTrue);
      expect(_flutterWmOpacity(t), 0.01);
      final buildsAtStart = builds.length;

      // 隱藏：只送空清單；圖片照舊烘著（_wmBakeRange 不看隱藏）→ 不重組
      final setsBeforeHide = overlaySets.length;
      toggleWm(t);
      await _waitUntil(t, () => overlaySets.length > setsBeforeHide);
      expect(overlaySets.last, isEmpty);
      expect(_flutterWmOpacity(t), isNull);
      await _wait(t, 800);
      expect(builds.length, buildsAtStart, reason: '隱藏不重組（圖片照舊烘著）');

      // 打開：清單送回去，原生畫在烘好的圖片之上；還是不重組
      overlaySets.clear();
      toggleWm(t);
      await _waitUntil(t, () => overlaySets.isNotEmpty || rejects > 0);
      expect(rejects, 0);
      expect(overlaySets.last, isNotEmpty);
      expect(_flutterWmOpacity(t), 0.01);
      await _wait(t, 800);
      expect(builds.length, buildsAtStart, reason: '打開也不重組（不閃）');
      expect(rejects, 0);

      await leave(t);
    });
  });
}
