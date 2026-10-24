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

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.playerLayer.value = false;
    analyzed.clear();
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    comp = FakeComp(b)
      ..duration = 5.0
      ..install();
    b.defaultBinaryMessenger.setMockMethodCallHandler(_face, (call) async {
      if (call.method == 'analyzeVideo') {
        analyzed.add((call.arguments as Map)['path'] as String);
        return _samples();
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
}
