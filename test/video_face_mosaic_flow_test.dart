// 影片的自動碼人臉（使用者在畫布選的甲案）：走真的編輯頁，從「加素材 →
// 馬賽克 → 自動碼人臉」進去，原生的找臉通道（markcut/face）換成假的。
//
// 守的是：
//   1. 找的是工作檔（1080p SDR，好解、時間跟原檔一樣）
//   2. 每個人一條軌、疊在最上面；片段的時間蓋住這個人出現的那段
//   3. 軌跡跟著臉走：播放頭在哪，預覽上的框就在那一刻臉的位置
//   4. 軌道標籤換成頭像（測試沒有抽幀通道，先放臉的圖示）
//   5. 點標籤＝這個人不碼：預覽留一圈白虛線，點虛線圈碼回去
//   6. 片段的 scale（捏合、縮放滑桿）乘在臉框大小上
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/mosaic_outline.dart';

import 'editor_harness.dart';

const _face = MethodChannel('markcut/face');

/// 兩個人、0~3 秒每 0.1 秒一格：甲從左往右走（x 0.20 → 0.50），乙站著不動
List<Object?> _samples() => [
  for (var i = 0; i <= 30; i++)
    {
      't': i / 10,
      'f': [
        [0.20 + 0.01 * i, 0.15, 0.10, 0.14],
        [0.75, 0.18, 0.08, 0.12],
      ],
    },
];

Finder _dashedRings() => find.byWidgetPredicate(
  (w) =>
      w is CustomPaint &&
      w.painter is MosaicOutlinePainter &&
      (w.painter as MosaicOutlinePainter).dashed,
);

void main() {
  late FakeComp comp;
  final analyzed = <String>[];
  final detected = <String>[];

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
    analyzed.clear();
    detected.clear();
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    comp = FakeComp(b)
      ..duration = 5.0
      ..install();
    b.defaultBinaryMessenger.setMockMethodCallHandler(_face, (call) async {
      if (call.method == 'analyzeVideo') {
        analyzed.add((call.arguments as Map)['path'] as String);
        return _samples();
      }
      // 圖片：兩張臉（轉正後的照片 0~1、左上原點）
      if (call.method == 'detectImage') {
        detected.add((call.arguments as Map)['path'] as String);
        return [
          {'x': 0.20, 'y': 0.20, 'w': 0.15, 'h': 0.20},
          {'x': 0.60, 'y': 0.25, 'w': 0.12, 'h': 0.16},
        ];
      }
      return null;
    });
  });

  tearDown(() {
    comp.uninstall();
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(_face, null);
  });

  Future<void> openWithVideo(WidgetTester t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(
          path: '/v.mp4',
          name: 'v',
          kind: ClipKind.video,
          duration: 10,
          w: 1920,
          h: 1080,
          workPath: '/v.work.mp4',
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
    });
    await tick(t, 15);
  }

  Future<void> autoFace(WidgetTester t) async {
    editorOf(t).onAddMedia(1);
    await tick(t, 15);
    await t.tap(find.text('馬賽克').last);
    await tick(t, 15);
    expect(find.text('自動碼人臉'), findsOneWidget, reason: '馬賽克要先跳選單（甲案）');
    expect(find.text('方框'), findsOneWidget);
    expect(find.text('筆刷'), findsOneWidget);
    await t.tap(find.text('自動碼人臉'));
    await settle(t, 10);
  }

  List<TimelineClip> faceClips(WidgetTester t) => [
    for (final c in modelOf(t).clips)
      if (modelOf(t).sourceOf(c).mosaicFace) c,
  ]..sort((a, b) => a.track.compareTo(b.track));

  testWidgets('加素材 → 馬賽克 → 自動碼人臉：每個人一條軌、框跟著臉走', (t) async {
    await openWithVideo(t);
    await autoFace(t);

    expect(analyzed, ['/v.work.mp4'], reason: '找臉要解工作檔');
    final faces = faceClips(t);
    expect(faces.length, 2, reason: '兩個人兩條');
    expect([for (final c in faces) c.track], [1, 2], reason: '疊在影片上面，一人一軌');
    for (final c in faces) {
      final s = modelOf(t).sourceOf(c);
      expect(s.kind, ClipKind.mosaic);
      expect(s.mosaicOval, isTrue);
      expect(s.mosaicPath, isNotNull);
      expect(s.mosaicFaceAt?.first, 0, reason: '頭像從影片（素材 0）抽');
      expect(c.offset, lessThanOrEqualTo(0.001));
      expect(c.end, greaterThan(2.9), reason: '要蓋到這個人最後出現的那一格');
    }
    expect(find.text('臉 1'), findsOneWidget, reason: '片段上寫誰是誰');
    expect(find.text('臉 2'), findsOneWidget);
    expect(
      find.byIcon(Icons.face_retouching_natural),
      findsNWidgets(4),
      reason: '兩條軌的標籤＋兩個片段上的小圖示（沒有抽幀通道，先放臉的圖示）',
    );

    // 甲在 1 秒時走到 x≈0.30+0.05（框中心），2 秒時≈0.45：跟著動
    double centerX(TimelineClip c, double at) {
      final keys = modelOf(t).sourceOf(c).mosaicPath!;
      final s = c.sourceTimeAt(at);
      for (var i = 0; i + 9 < keys.length; i += 5) {
        if (keys[i] <= s && keys[i + 5] >= s) {
          final f = (s - keys[i]) / (keys[i + 5] - keys[i]);
          return keys[i + 1] + (keys[i + 6] - keys[i + 1]) * f;
        }
      }
      return keys[1];
    }

    final a = faces.first;
    expect(centerX(a, 2.0) - centerX(a, 1.0), greaterThan(0.05));
    await settle(t, 80);
  });

  testWidgets('點標籤＝這個人不碼：預覽留白虛線圈，點圈碼回去', (t) async {
    await openWithVideo(t);
    await autoFace(t);
    final a = faceClips(t).first;
    editorOf(t).onSeek(1.0);
    await tick(t, 5);
    expect(_dashedRings(), findsNothing, reason: '碼著的臉不畫虛線');

    editorOf(t).onToggleHidden!(a.track);
    await tick(t, 5);
    expect(editorOf(t).hiddenTracks, {a.track});
    expect(
      find.byIcon(Icons.face_retouching_off),
      findsOneWidget,
      reason: '標籤換成「不碼」的臉',
    );
    expect(_dashedRings(), findsOneWidget, reason: '不碼的臉要留一圈虛線');

    // 圈本身不吃手勢（IgnorePointer）：點擊由中央判定層統一分派
    await t.tap(_dashedRings(), warnIfMissed: false);
    await tick(t, 5);
    expect(editorOf(t).hiddenTracks, isEmpty, reason: '點虛線圈要碼回去');
    expect(_dashedRings(), findsNothing);
    await settle(t, 80);
  });

  testWidgets('左邊修剪找臉的片段：框還是對著同一刻的臉，拉不過這個人出現之前', (t) async {
    await openWithVideo(t);
    await autoFace(t);
    final a = faceClips(t).first;
    final keys = modelOf(t).sourceOf(a).mosaicPath!;
    final before = mosaicPathAt(keys, a.sourceTimeAt(2.0))!;
    final end0 = a.end;

    editorOf(t).onTrimStart?.call();
    editorOf(t).onTrim(a.id, 0.5, true);
    editorOf(t).onTrimEnd?.call();
    await tick(t, 5);
    expect(a.offset, closeTo(0.5, 1e-6), reason: '左邊往右收 0.5 秒');
    expect(a.end, closeTo(end0, 1e-6), reason: '右邊不動');
    final after = mosaicPathAt(keys, a.sourceTimeAt(2.0))!;
    expect(after.cx, closeTo(before.cx, 1e-9), reason: '同一個時間點，框在同一個位置');
    expect(after.cy, closeTo(before.cy, 1e-9));

    // 往左拉過頭：停在這個人第一次出現的地方，不會多出一段沒有臉的片段
    editorOf(t).onTrimStart?.call();
    editorOf(t).onTrim(a.id, -5, true);
    editorOf(t).onTrimEnd?.call();
    await tick(t, 5);
    expect(a.sourceTimeAt(a.offset), greaterThanOrEqualTo(keys.first - 1e-6));
    expect(a.offset, greaterThanOrEqualTo(0));
    await settle(t, 80);
  });

  testWidgets('片段的 scale 乘在臉框上：送給合成的軌跡、預覽的虛線圈一起變', (t) async {
    await openWithVideo(t);
    await autoFace(t);
    final a = faceClips(t).first;
    final keys = modelOf(t).sourceOf(a).mosaicPath!;
    final base = a.mosaicPathOnTimeline(keys);
    a.scale = 2.0;
    final big = a.mosaicPathOnTimeline(keys);
    for (var i = 0; i + 4 < keys.length; i += 5) {
      expect(big[i], base[i], reason: '時間不變');
      expect(big[i + 1], base[i + 1], reason: '中心不變');
      expect(big[i + 3], closeTo(base[i + 3] * 2, 1e-9));
      expect(big[i + 4], closeTo(base[i + 4] * 2, 1e-9));
    }

    editorOf(t).onSeek(1.0);
    editorOf(t).onToggleHidden!(a.track);
    await tick(t, 5);
    final w2 = t.getSize(_dashedRings()).width;
    a.scale = 1.0;
    editorOf(t).onToggleHidden!(a.track);
    editorOf(t).onToggleHidden!(a.track);
    await tick(t, 5);
    final w1 = t.getSize(_dashedRings()).width;
    expect(w2, closeTo(w1 * 2, 1.0), reason: '預覽的框也乘 scale');
    await settle(t, 80);
  });

  // ── 10-25：三種馬賽克各開各的樣式表、標題寫明（使用者指定）；
  //    圖片也能自動碼人臉 ──
  Future<void> openSheet(WidgetTester t, TimelineClip c) async {
    editorOf(t).onTapSelectedClip!(c.id);
    await tick(t, 15);
  }

  testWidgets('點人臉馬賽克：標題寫自動人臉馬賽克，只有像素化／模糊；模糊柔邊先給一點', (t) async {
    await openWithVideo(t);
    await autoFace(t);
    final a = faceClips(t).first;
    await openSheet(t, a);
    expect(find.text('自動人臉馬賽克'), findsOneWidget);
    for (final x in const ['像素化', '模糊', '大小', '濃度']) {
      expect(find.text(x), findsWidgets, reason: '少了「$x」');
    }
    // 使用者：純色、筆刷都不用；圓／方也不用（一律圓圈）；像素化沒有柔邊
    for (final x in const ['純色', '筆刷', '圓', '方', '縮放', '柔邊']) {
      expect(find.text(x), findsNothing, reason: '人臉馬賽克不該有「$x」');
    }
    await t.tap(find.text('模糊'));
    await tick(t, 10);
    final st = modelOf(t).sourceOf(a).mosaicStyle!;
    expect(st.type, 1);
    expect(
      st.feather,
      closeTo(kMosaicFeatherDefault, 1e-9),
      reason: '柔邊先給一點預設',
    );
    expect(find.text('柔邊'), findsOneWidget);
    await settle(t, 80);
  });

  testWidgets('人臉舊資料存成方的、純色的：打開樣式表就改成圓的、像素化', (t) async {
    await openWithVideo(t);
    await autoFace(t);
    final a = faceClips(t).first;
    final s = modelOf(t).sourceOf(a);
    s.mosaicOval = false;
    s.mosaicStyle!.type = 2;
    await openSheet(t, a);
    expect(s.mosaicOval, isTrue, reason: '人臉一律圓圈');
    expect(s.mosaicStyle!.type, 0, reason: '人臉沒有純色了');
    await settle(t, 80);
  });

  testWidgets('點方框馬賽克：標題寫方框馬賽克，只有像素化／模糊（沒有純色、筆刷）', (t) async {
    await openWithVideo(t);
    editorOf(t).onAddMedia(1);
    await tick(t, 15);
    await t.tap(find.text('馬賽克').last);
    await tick(t, 15);
    await t.tap(find.text('方框'));
    await settle(t, 10);
    final box = modelOf(t).clips.firstWhere((c) {
      final s = modelOf(t).sourceOf(c);
      return s.kind == ClipKind.mosaic &&
          !s.mosaicFace &&
          s.mosaicStroke == null;
    });
    await openSheet(t, box);
    expect(find.text('方框馬賽克'), findsOneWidget);
    expect(find.text('像素化'), findsOneWidget);
    expect(find.text('模糊'), findsOneWidget);
    for (final x in const ['純色', '筆刷', '圓', '方']) {
      expect(find.text(x), findsNothing, reason: '方框馬賽克不該有「$x」');
    }
    await settle(t, 80);
  });

  testWidgets('點筆刷馬賽克：標題寫筆刷馬賽克，有像素化／模糊／純色／筆刷；柔邊先給一點', (t) async {
    await openWithVideo(t);
    late TimelineClip stroke;
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(
          path: '',
          name: '筆刷馬賽克',
          kind: ClipKind.mosaic,
          duration: 3600,
          mosaicStyle: MosaicStyle(),
          mosaicStroke: [0.2, 0.2, 0.5, 0.5],
          mosaicBrush: 0.1,
        ),
      );
      stroke = TimelineClip(
        id: tl.nextId(),
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: 3,
        offset: 0,
        track: 1,
      );
      tl.clips.add(stroke);
    });
    await tick(t, 10);
    await openSheet(t, stroke);
    expect(find.text('筆刷馬賽克'), findsOneWidget);
    for (final x in const ['像素化', '模糊', '純色', '筆刷', '粗細']) {
      expect(find.text(x), findsWidgets, reason: '筆刷馬賽克少了「$x」');
    }
    final st = modelOf(t).sourceOf(stroke).mosaicStyle!;
    await t.tap(find.text('模糊'));
    await tick(t, 8);
    expect(st.feather, closeTo(kMosaicFeatherDefault, 1e-9));
    await t.tap(find.text('純色'));
    await tick(t, 8);
    expect(st.type, 2);
    expect(
      st.feather,
      closeTo(kMosaicFeatherDefault, 1e-9),
      reason: '純色的柔邊也先給一點',
    );
    expect(find.text('顏色'), findsOneWidget);
    await settle(t, 80);
  });

  testWidgets('圖片也能自動碼人臉：每張臉一條軌、整段不動、蓋住圖片那段', (t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(
          path: '/p.jpg',
          name: 'p',
          kind: ClipKind.image,
          duration: 3600,
          w: 1000,
          h: 800,
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 4,
          offset: 0,
          track: 0,
        ),
      );
    });
    await tick(t, 15);
    await autoFace(t);
    expect(detected, ['/p.jpg'], reason: '圖片要走照片的找臉');
    expect(analyzed, isEmpty, reason: '圖片不該走影片的找臉');
    final faces = faceClips(t);
    expect(faces.length, 2, reason: '兩張臉兩條');
    for (final c in faces) {
      final s = modelOf(t).sourceOf(c);
      expect(s.mosaicOval, isTrue);
      expect(s.mosaicFaceAt?.first, 0, reason: '頭像從圖片（素材 0）裁');
      expect(c.offset, closeTo(0, 1e-6));
      expect(c.end, closeTo(4, 0.05), reason: '要蓋住圖片那 4 秒');
      final keys = s.mosaicPath!;
      expect(keys.length, greaterThanOrEqualTo(10));
      for (var i = 5; i + 4 < keys.length; i += 5) {
        expect(keys[i + 1], closeTo(keys[1], 1e-9), reason: '圖片的臉不會動');
        expect(keys[i + 2], closeTo(keys[2], 1e-9));
      }
    }
    await settle(t, 80);
  });
  // 10-25 Android：影片的找臉回 {samples, info}（帶流水帳），iOS 照舊回清單
  void answerVideo(Object? Function() reply) {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(_face, (call) async {
          if (call.method == 'analyzeVideo') {
            analyzed.add((call.arguments as Map)['path'] as String);
            return reply();
          }
          return null;
        });
  }

  testWidgets('Android 回 {samples, info}：照樣每個人一條軌', (t) async {
    answerVideo(() => {'samples': _samples(), 'info': '解 90 格／找 31 格／臉 62'});
    await openWithVideo(t);
    await autoFace(t);
    expect(analyzed, ['/v.work.mp4']);
    expect(faceClips(t).length, 2, reason: '兩個人兩條');
    await settle(t, 80);
  });

  testWidgets('Android 一張臉都沒找到：提示帶著流水帳（分得出真的沒臉還是走不通）', (t) async {
    const info = '解 90 格／找 31 格／臉 0／沒影像 0／失敗 0｜c2.qti.avc.decoder，轉 90°';
    answerVideo(
      () => {
        'samples': [
          for (var i = 0; i <= 30; i++) {'t': i / 10, 'f': const []},
        ],
        'info': info,
      },
    );
    await openWithVideo(t);
    await autoFace(t);
    expect(faceClips(t), isEmpty);
    expect(find.textContaining('沒有找到臉'), findsOneWidget);
    expect(find.textContaining(info), findsOneWidget);
    // 帶原因的提示多留 6 秒：假時間推過去，計時器才收得乾淨
    await t.pump(const Duration(seconds: 7));
    await settle(t, 20);
  });

  testWidgets('Android 整支走不通：提示帶著原因，不加東西', (t) async {
    answerVideo(
      () => throw PlatformException(
        code: 'face_failed',
        message:
            '找臉｜IllegalStateException @ MainActivity.analyzeVideoFaces'
            '｜每一格都找不了：NullPointerException: boom',
        details: '解 90 格／找 31 格／臉 0／沒影像 0／失敗 31',
      ),
    );
    await openWithVideo(t);
    await autoFace(t);
    expect(faceClips(t), isEmpty);
    expect(find.textContaining('這支影片沒辦法自動找臉'), findsOneWidget);
    expect(find.textContaining('每一格都找不了'), findsOneWidget);
    // 帶原因的提示多留 6 秒：假時間推過去，計時器才收得乾淨
    await t.pump(const Duration(seconds: 7));
    await settle(t, 20);
  });
}
