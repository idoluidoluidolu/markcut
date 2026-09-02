import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/widgets/timeline_editor.dart';

TimelineModel _model() {
  final tl = TimelineModel();
  // 0: 影片（長）
  tl.sources.add(
    MediaSource(
      path: 'v.mp4',
      name: 'v',
      kind: ClipKind.video,
      w: 1080,
      h: 1920,
      duration: 30,
    ),
  );
  // 1: 圖片（短，3 秒）
  tl.sources.add(
    MediaSource(
      path: 'p.png',
      name: 'p',
      kind: ClipKind.image,
      w: 800,
      h: 800,
      duration: 3600,
    ),
  );
  tl.clips.add(
    TimelineClip(
      id: tl.nextId(),
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 28.5,
      offset: 0,
      track: 0,
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
  return tl;
}

void main() {
  setUpAll(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(1200, 2200);
    v.devicePixelRatio = 1.0;
  });

  testWidgets('點一下時間軸上的圖片素材要能選取', (t) async {
    final tl = _model();
    final imageClipId = tl.clips[1].id;
    var selected = -1;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: TimelineEditor(
              timeline: tl,
              thumbs: <int, List<Uint8List>>{},
              selectedId: selected,
              playhead: ValueNotifier<double>(0),
              pxPerSec: 30,
              trackScale: 1,
              scrollController: scroll,
              onSelect: (id) => selected = id,
              onSeek: (_) {},
              onTrim: (_, _, _) {},
              onDrop: (_, _, _, _) {},
              onAddMedia: (_) {},
              onReorderTrack: (_, _) {},
              mutedTracks: const {},
              onToggleMute: (_) {},
              onLongPressClip: (_, _) {},
              onLongPressEmpty: (_, _, _) {},
              onSelectWm: () {},
              onMoveWm: (_) {},
              onTrimWm: (_, _) {},
              selectedTrack: -1,
              snapEnabled: true,
              extraTracks: 0,
              wmLabel: '',
              wmSelected: false,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // 找到圖片素材那一塊（3 秒 × 30px = 90px 寬）
    final blocks = find.byKey(ValueKey('clip$imageClipId'));
    expect(blocks, findsOneWidget, reason: '圖片素材要畫得出來');

    final r = t.getRect(blocks);
    // 純粹「點一下」：按下、不移動、放開
    await t.tapAt(r.center);
    await t.pumpAndSettle();

    expect(
      selected,
      imageClipId,
      reason: '點一下圖片素材應該要選取它（目前拖曳辨識器可能把點擊吃掉）',
    );
  });

  testWidgets('影片已被選取時，點圖片素材要換選成圖片', (t) async {
    final tl = _model();
    final videoClipId = tl.clips[0].id;
    final imageClipId = tl.clips[1].id;
    var selected = videoClipId; // 進來時影片是選取中的
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: StatefulBuilder(
              builder: (context, setLocal) => TimelineEditor(
                timeline: tl,
                thumbs: <int, List<Uint8List>>{},
                selectedId: selected,
                playhead: ValueNotifier<double>(0),
                pxPerSec: 30,
                trackScale: 1,
                scrollController: scroll,
                onSelect: (id) => setLocal(() => selected = id),
                onSeek: (_) {},
                onTrim: (_, _, _) {},
                onDrop: (_, _, _, _) {},
                onAddMedia: (_) {},
                onReorderTrack: (_, _) {},
                mutedTracks: const {},
                onToggleMute: (_) {},
                onLongPressClip: (_, _) {},
                onLongPressEmpty: (_, _, _) {},
                onSelectWm: () {},
                onMoveWm: (_) {},
                onTrimWm: (_, _) {},
                selectedTrack: -1,
                snapEnabled: true,
                extraTracks: 0,
                wmLabel: '',
                wmSelected: false,
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final r = t.getRect(find.byKey(ValueKey('clip$imageClipId')));
    await t.tapAt(r.center);
    await t.pumpAndSettle();
    expect(selected, imageClipId, reason: '應該換選成圖片素材');
  });

  testWidgets('手指有一點點抖動的點擊，一樣要選得到', (t) async {
    final tl = _model();
    final imageClipId = tl.clips[1].id;
    var selected = -1;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: TimelineEditor(
              timeline: tl,
              thumbs: <int, List<Uint8List>>{},
              selectedId: selected,
              playhead: ValueNotifier<double>(0),
              pxPerSec: 30,
              trackScale: 1,
              scrollController: scroll,
              onSelect: (id) => selected = id,
              onSeek: (_) {},
              onTrim: (_, _, _) {},
              onDrop: (_, _, _, _) {},
              onAddMedia: (_) {},
              onReorderTrack: (_, _) {},
              mutedTracks: const {},
              onToggleMute: (_) {},
              onLongPressClip: (_, _) {},
              onLongPressEmpty: (_, _, _) {},
              onSelectWm: () {},
              onMoveWm: (_) {},
              onTrimWm: (_, _) {},
              selectedTrack: -1,
              snapEnabled: true,
              extraTracks: 0,
              wmLabel: '',
              wmSelected: false,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final r = t.getRect(find.byKey(ValueKey('clip$imageClipId')));
    final g = await t.startGesture(r.center);
    await t.pump(const Duration(milliseconds: 20));
    await g.moveBy(const Offset(2, 1)); // 手指難免抖一下
    await t.pump(const Duration(milliseconds: 20));
    await g.up();
    await t.pumpAndSettle();
    expect(selected, imageClipId);
  });

  testWidgets('螢幕上已經有另一根手指時，點圖片素材仍要選得到', (t) async {
    final tl = _model();
    final imageClipId = tl.clips[1].id;
    final videoClipId = tl.clips[0].id;
    var selected = -1;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: TimelineEditor(
              timeline: tl,
              thumbs: <int, List<Uint8List>>{},
              selectedId: selected,
              playhead: ValueNotifier<double>(0),
              pxPerSec: 30,
              trackScale: 1,
              scrollController: scroll,
              onSelect: (id) => selected = id,
              onSeek: (_) {},
              onTrim: (_, _, _) {},
              onDrop: (_, _, _, _) {},
              onAddMedia: (_) {},
              onReorderTrack: (_, _) {},
              mutedTracks: const {},
              onToggleMute: (_) {},
              onLongPressClip: (_, _) {},
              onLongPressEmpty: (_, _, _) {},
              onSelectWm: () {},
              onMoveWm: (_) {},
              onTrimWm: (_, _) {},
              selectedTrack: -1,
              snapEnabled: true,
              extraTracks: 0,
              wmLabel: '',
              wmSelected: false,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final vr = t.getRect(find.byKey(ValueKey('clip$videoClipId')));
    final ir = t.getRect(find.byKey(ValueKey('clip$imageClipId')));

    // 第一根手指按在影片上不放（例如另一手還沒離開螢幕）
    final hold = await t.startGesture(Offset(vr.left + 200, vr.center.dy));
    await t.pump(const Duration(milliseconds: 30));
    selected = -1; // 只看第二根手指的結果

    // 第二根手指點圖片素材
    final tap = await t.startGesture(ir.center);
    await t.pump(const Duration(milliseconds: 30));
    await tap.up();
    await t.pump(const Duration(milliseconds: 30));
    await hold.up();
    await t.pumpAndSettle();

    expect(selected, imageClipId, reason: '第二根手指的點擊不該被吃掉');
  });

  testWidgets('點一下影片素材也要能選取', (t) async {
    final tl = _model();
    final videoClipId = tl.clips[0].id;
    var selected = -1;
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: TimelineEditor(
              timeline: tl,
              thumbs: <int, List<Uint8List>>{},
              selectedId: selected,
              playhead: ValueNotifier<double>(0),
              pxPerSec: 30,
              trackScale: 1,
              scrollController: scroll,
              onSelect: (id) => selected = id,
              onSeek: (_) {},
              onTrim: (_, _, _) {},
              onDrop: (_, _, _, _) {},
              onAddMedia: (_) {},
              onReorderTrack: (_, _) {},
              mutedTracks: const {},
              onToggleMute: (_) {},
              onLongPressClip: (_, _) {},
              onLongPressEmpty: (_, _, _) {},
              onSelectWm: () {},
              onMoveWm: (_) {},
              onTrimWm: (_, _) {},
              selectedTrack: -1,
              snapEnabled: true,
              extraTracks: 0,
              wmLabel: '',
              wmSelected: false,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final r = t.getRect(find.byKey(ValueKey('clip$videoClipId')));
    await t.tapAt(Offset(r.left + 40, r.center.dy));
    await t.pumpAndSettle();

    expect(selected, videoClipId);
  });
}
