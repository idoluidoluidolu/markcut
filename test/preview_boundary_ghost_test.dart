// 迴歸守門：實機回報「上一張照片卻會出現在下一張照片沒有覆蓋到的地方」。
//
// 場景（照實機截圖重建）：一條軌上六張照片頭尾相接、每張 0.3 秒——人像
// 照、兩張橫的室內照、再來三張細長的手機截圖。播放頭停在 0.9（第三張
// 室內照的結尾＝第一張截圖的開頭），截圖比畫布窄，左右的空白裡露出的
// 卻是上一張室內照，不是畫布的黑底。
//
// 根因：預覽的「這一刻畫哪些片段」（TimelineModel.videoAt／videosAt／
// overlaysAt）用的是頭尾都含的 coversForDisplay——停在交界那一點時，
// 結束的上一段跟開始的下一段同時算在畫面上，兩層一起畫，上一段墊在
// 下面、從下一段沒蓋到的地方露出來。播放頭拖曳會吸附到素材頭尾
//（12px 內當場黏在邊上，見編輯器 _nearestEdge），0.3 秒的短片段幾乎
// 整段都在吸附範圍裡——所以不是偶發，是拖到哪張都看得到上一張。
// 匯出兩條路（FFmpeg 的 _window、原生 CI 合成器的分段）一直是半開區間，
// 只有預覽多畫了一層。
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';

import 'editor_harness.dart';

/// 指定長寬的純色 PNG（畫面上要分得出是哪一張）
Uint8List _png(int w, int h, int r, int g, int b) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(im));
}

/// 預覽畫布上的圖片圖層：編輯器畫靜態圖用 Image.memory＋BoxFit.fill；
/// 時間軸縮圖、換序清單那些都是 BoxFit.cover，不會被算進來
Finder get _previewStills => find.byWidgetPredicate(
  (w) => w is Image && w.fit == BoxFit.fill && w.image is MemoryImage,
);

/// 預覽上畫著的是哪幾張圖（照畫的順序，由下往上），用位元組認
List<String> _drawn(WidgetTester t, Map<String, Uint8List> files) {
  return [
    for (final e in _previewStills.evaluate())
      files.entries
          .firstWhere(
            (f) => listEquals(
              ((e.widget as Image).image as MemoryImage).bytes,
              f.value,
            ),
            orElse: () => MapEntry('?', Uint8List(0)),
          )
          .key,
  ];
}

/// 純模型的時間軸：每個片段給（種類、軌、開頭、長度），依序排進去
TimelineModel _model(List<(ClipKind, int, double, double)> specs) {
  final tl = TimelineModel();
  for (final (kind, track, offset, length) in specs) {
    tl.sources.add(
      MediaSource(path: '/m$track.x', name: 'm', kind: kind, duration: 3600),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: length,
        offset: offset,
        track: track,
      ),
    );
  }
  return tl;
}

List<int> _ids(List<TimelineClip> cs) => [for (final c in cs) c.id];

void main() {
  group('TimelineModel：這一刻畫面上有哪些片段', () {
    test('同軌交界只算接手的下一段；停在總長才留最後一格', () {
      final tl = _model([
        (ClipKind.image, 0, 0, 0.3),
        (ClipKind.image, 0, 0.3, 0.3),
      ]);
      final seam = tl.clips[0].end;
      expect(_ids(tl.overlaysAt(seam)), [1], reason: '交界那一刻上一段已播完');
      expect(tl.showsAt(tl.clips[0], seam), isFalse);
      expect(_ids(tl.overlaysAt(0.15)), [0]);
      expect(_ids(tl.overlaysAt(tl.duration)), [1], reason: '播完留最後一格');
    });

    test('別軌接手也一樣：結束那段不論在上層或下層都不畫', () {
      for (final (prevTrack, nextTrack) in [(0, 1), (1, 0)]) {
        final tl = _model([
          (ClipKind.image, prevTrack, 0, 1),
          (ClipKind.image, nextTrack, 1, 1),
        ]);
        expect(
          _ids(tl.overlaysAt(1)),
          [1],
          reason: '上一段在軌 $prevTrack、下一段在軌 $nextTrack：只畫下一段',
        );
      }
    });

    test('影片接圖片、圖片接影片：跨種類接手', () {
      final a = _model([(ClipKind.video, 0, 0, 1), (ClipKind.image, 0, 1, 1)]);
      expect(a.videoAt(1), isNull);
      expect(a.videosAt(1), isEmpty);
      expect(_ids(a.overlaysAt(1)), [1]);
      final b = _model([(ClipKind.image, 0, 0, 1), (ClipKind.video, 0, 1, 1)]);
      expect(b.overlaysAt(1), isEmpty);
      expect(b.videoAt(1)?.id, 1);
      expect(_ids(b.videosAt(1)), [1]);
    });

    test('影片同軌交界：videosAt 跟 videoAt 都是接手那段（預覽與成品同一個）', () {
      final tl = _model([(ClipKind.video, 0, 0, 2), (ClipKind.video, 0, 2, 2)]);
      expect(_ids(tl.videosAt(2)), [1]);
      expect(tl.videoAt(2)?.id, 1);
    });

    test('後面是空隙、沒人接手：停在結尾留最後一格', () {
      final tl = _model([(ClipKind.image, 0, 0, 1), (ClipKind.image, 0, 2, 1)]);
      expect(_ids(tl.overlaysAt(1)), [0]);
      expect(tl.overlaysAt(1.5), isEmpty);
    });

    test('別的片段還在播：結束那段照半開區間收掉（跟匯出一致）', () {
      final tl = _model([(ClipKind.video, 0, 0, 5), (ClipKind.text, 1, 0, 2)]);
      expect(tl.overlaysAt(2), isEmpty);
      expect(tl.videoAt(2)?.id, 0);
      // 全部一起播到總長：都留著
      final end = _model([
        (ClipKind.video, 0, 0, 5),
        (ClipKind.image, 1, 3, 2),
      ]);
      expect(end.videoAt(5)?.id, 0);
      expect(_ids(end.overlaysAt(5)), [1]);
    });

    test('聲音、馬賽克不出畫面：不算接手', () {
      final tl = _model([
        (ClipKind.image, 0, 0, 1),
        (ClipKind.audio, 1, 0, 5),
        (ClipKind.mosaic, 2, 0, 5),
      ]);
      expect(_ids(tl.overlaysAt(1)), [0, 2], reason: '圖片留最後一格，馬賽克照常');
    });

    test('隱藏軌不算接手，也不回傳', () {
      final tl = _model([(ClipKind.image, 0, 0, 1), (ClipKind.image, 1, 1, 1)]);
      expect(_ids(tl.overlaysAt(1, skipTracks: {1})), [0]);
      expect(tl.showsAt(tl.clips[0], 1, skipTracks: {1}), isTrue);
      expect(_ids(tl.overlaysAt(1)), [1]);
      expect(tl.overlaysAt(0.5, skipTracks: {0}), isEmpty);
    });

    test('接點差一個浮點尾數也是同一個交界', () {
      final tl = _model([
        (ClipKind.image, 0, 0, 1.5),
        (ClipKind.image, 0, 1.5, 1),
      ]);
      // 變速切開之類的運算讓上一段的 end 比下一段的 offset 多一個尾數
      tl.clips[0].trimEnd = 1.5 + 4e-16;
      expect(tl.clips[0].end, greaterThan(tl.clips[1].offset));
      expect(_ids(tl.overlaysAt(tl.clips[1].offset)), [1]);
    });
  });

  late Directory tmp;
  late Map<String, Uint8List> files;
  late Map<String, String> paths;

  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
    tmp = Directory.systemTemp.createTempSync('markcut_ghost_');
    // 人像（3:4，畫布跟著第一個素材＝直式）、橫的室內照、細長截圖
    files = {
      'person': _png(24, 32, 0, 200, 0),
      'room': _png(32, 16, 200, 0, 0),
      'shot': _png(12, 32, 0, 0, 200),
    };
    paths = {
      for (final e in files.entries)
        e.key: (File(
          '${tmp.path}${Platform.pathSeparator}${e.key}.png',
        )..writeAsBytesSync(e.value)).path,
    };
  });
  tearDownAll(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 六張照片頭尾相接排在同一條軌上。offset 用「上一段的 end」接起來，
  /// 跟編輯器接片段的算法一樣（0.3＋0.3＋0.3 在浮點裡是 0.8999…，
  /// 交界的值要跟真的時間軸一模一樣才測得到）
  Map<String, dynamic> draft(List<String> order, {double each = 0.3}) {
    final names = files.keys.toList();
    final clips = <TimelineClip>[];
    for (var i = 0; i < order.length; i++) {
      clips.add(
        TimelineClip(
          id: i + 1,
          sourceIndex: names.indexOf(order[i]),
          trimStart: 0,
          trimEnd: each,
          offset: i == 0 ? 0 : clips[i - 1].end,
          track: 0,
        ),
      );
    }
    return {
      'savedAt': '2026-10-07T00:00:00.000',
      'sources': [
        for (final n in names)
          MediaSource(
            path: paths[n]!,
            name: '$n.png',
            kind: ClipKind.image,
            w: img.decodePng(files[n]!)!.width,
            h: img.decodePng(files[n]!)!.height,
            duration: 3600,
          ).toJson(),
      ],
      'clips': [for (final c in clips) c.toJson()],
      'speed': 1.0,
      'ratio': 0,
      'res': 0,
      'quality': 0,
      'wmStart': 0.0,
      'extraTracks': 0,
    };
  }

  const order = ['person', 'room', 'room', 'shot', 'shot', 'shot'];

  testWidgets('停在兩張照片的交界：只畫下一張，上一張不從空白處露出來', (t) async {
    await t.pumpWidget(editorApp(VideoEditorScreen(draft: draft(order))));
    await settle(t);
    final tl = modelOf(t);
    expect(tl.clips, hasLength(6));
    // 起點：只有第一張
    expect(_drawn(t, files), ['person']);

    // 每一個交界都要只剩「接手的那一張」——實機截圖那一刻是第三張
    // 室內照接第一張截圖（0.9）
    final sorted = [...tl.clips]..sort((a, b) => a.offset.compareTo(b.offset));
    for (var i = 0; i + 1 < sorted.length; i++) {
      final seam = sorted[i].end;
      expect(sorted[i + 1].offset, seam, reason: '交界要頭尾相接');
      editorOf(t).onSeek(seam);
      await settle(t, 3);
      expect(playheadOf(t), seam, reason: '播放頭要停在交界上');
      expect(
        _drawn(t, files),
        [order[i + 1]],
        reason:
            '播放頭停在 ${seam.toStringAsFixed(3)}（第 ${i + 1}、${i + 2} 張'
            '的交界）：上一段已經播完，畫面只能有接手的那一張——'
            '多畫一層就是上一張從下一張沒蓋到的地方露出來',
      );
    }

    // 實機截圖那一刻（室內照 → 截圖，0.9）直接看像素：截圖只有畫布一半
    // 寬，左右兩條空白必須什麼都沒畫（透出底下畫布的黑），不能是室內照
    // 的紅
    editorOf(t).onSeek(sorted[2].end);
    await settle(t, 3);
    final band = await _previewPixel(t, 0.1, 0.5);
    expect(band.$4, 0, reason: '截圖左邊的空白要透出畫布黑底，實際畫了 $band');
    final middle = await _previewPixel(t, 0.5, 0.5);
    expect((middle.$1, middle.$2, middle.$3), (0, 0, 200), reason: '中間是截圖');

    // 預設縮放下 0.3 秒的片段整段都在吸附範圍裡（每秒 60px、吸附半徑
    // 12px＝0.2 秒）：停在片段中間也會被吸到交界上——實機「拖到哪張
    // 都看得到上一張」就是這樣來的。吸到哪一邊都只能畫截圖
    editorOf(t).onSeek(1.05);
    await settle(t, 3);
    expect(_drawn(t, files), ['shot'], reason: '播放頭在 ${playheadOf(t)}');

    // 停在總長（播完）：最後一張照舊留著，不能變黑——
    // coversForDisplay 本來要守的就是這一格
    final end = tl.duration;
    editorOf(t).onSeek(end);
    await settle(t, 3);
    expect(playheadOf(t), end);
    expect(_drawn(t, files), ['shot'], reason: '播完要停在最後一格，不是黑畫面');

    await t.pumpWidget(const SizedBox());
    await settle(t, 3);
  });

  testWidgets('交界後面是空隙：停在上一張的結尾照舊留著那一張（沒人接手才留）', (t) async {
    await t.pumpWidget(
      editorApp(VideoEditorScreen(draft: draft(['room', 'shot']))),
    );
    await settle(t);
    // 第二張往後挪，中間空出 1.5 秒（空隙中間離兩邊都超過吸附上限 0.5 秒）
    VideoEditorScreen.debugTimeline!((tl) {
      final second = tl.clips.firstWhere((c) => c.id == 2);
      second.offset += 1.5;
    });
    await settle(t, 3);
    final first = clipOf(t, 1);
    editorOf(t).onSeek(first.end);
    await settle(t, 3);
    expect(playheadOf(t), first.end);
    expect(_drawn(t, files), [
      'room',
    ], reason: '停在結尾、後面沒有片段接手：留最後一格（跟播完停在總長同一套）');
    // 空隙中間：什麼都沒有，露出畫布的黑底
    editorOf(t).onSeek(first.end + 0.75);
    await settle(t, 3);
    expect(_drawn(t, files), isEmpty);
    // 空隙的另一頭：第二張接手
    editorOf(t).onSeek(clipOf(t, 2).offset);
    await settle(t, 3);
    expect(_drawn(t, files), ['shot']);

    await t.pumpWidget(const SizedBox());
    await settle(t, 3);
  });

  testWidgets('iOS 合成播放器接手時（有影片）：疊在影片上的照片交界一樣只畫接手那張', (t) async {
    // 有影片時畫面由原生合成出，但壓在所有影片之上的圖片不烘進合成，
    // 照舊是 Flutter 畫在合成畫面上面（CompPlayer.bakedImageIds）——
    // 走的是同一個 overlaysAt，交界一樣會疊兩張
    final playerLayer = Diag.playerLayer.value;
    Diag.playerLayer.value = false; // 沒有真的 UiKitView：合成畫面走 Texture
    addTearDown(() => Diag.playerLayer.value = playerLayer);
    final comp = FakeComp(t.binding)..install();
    addTearDown(comp.uninstall);
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(draft: draft(['room', 'room', 'room', 'shot'])),
      ),
    );
    await settle(t);
    VideoEditorScreen.debugTimeline!((tl) {
      for (final c in tl.clips) {
        c.track = 1;
      }
      tl.sources.add(
        MediaSource(
          path: '/v.mp4',
          name: 'v',
          kind: ClipKind.video,
          duration: 100,
          workPath: '/v.work.mp4',
        ),
      );
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: tl.sources.length - 1,
          trimStart: 0,
          trimEnd: tl.duration,
          offset: 0,
          track: 0,
        ),
      );
    });
    await settle(t, 15);
    expect(comp.builds, greaterThan(0), reason: '合成播放器要組起來');
    expect(find.byType(Texture), findsOneWidget, reason: '畫面由合成出');

    final seam = clipOf(t, 3).end; // 第三張室內照接截圖
    editorOf(t).onSeek(seam);
    await settle(t, 3);
    expect(playheadOf(t), seam);
    expect(_drawn(t, files), ['shot'], reason: '合成上面那層也只能有接手的那張');

    await t.pumpWidget(const SizedBox());
    await settle(t, 3);
  });
}

/// 預覽圖層（編輯器包在 RepaintBoundary 裡的那一層，畫布黑底在它
/// 底下）在 ([fx], [fy]) 比例位置的 RGBA
Future<(int, int, int, int)> _previewPixel(
  WidgetTester t,
  double fx,
  double fy,
) async {
  final boundary = t.renderObject<RenderRepaintBoundary>(
    find
        .ancestor(
          of: _previewStills.first,
          matching: find.byType(RepaintBoundary),
        )
        .first,
  );
  final rgba = await t.runAsync(() async {
    final im = await boundary.toImage();
    try {
      final data = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
      final x = (im.width * fx).floor().clamp(0, im.width - 1);
      final y = (im.height * fy).floor().clamp(0, im.height - 1);
      final i = (y * im.width + x) * 4;
      return (
        data!.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
        data.getUint8(i + 3),
      );
    } finally {
      im.dispose();
    }
  });
  return rgba!;
}
