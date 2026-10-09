// 時間軸的對齊線（使用者：「對齊時要有垂直的線暗示切齊其他素材」）：
// 拖曳片段、拉修剪把手的時候，邊緣切齊別的素材的頭尾（或片頭）就在那個
// 時間點畫一條直線貫穿所有軌；沒切齊、放手之後都不畫。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/widgets/timeline_editor.dart';

const _pps = 30.0;

/// 第 1 軌（上）：要拖的那段 M，0~2 秒、已選取。
/// 第 0 軌（下）：B，3~7 秒——M 跟它在不同軌，切齊只能靠對齊線看
class _Scene {
  final tl = TimelineModel();
  late final TimelineClip m;
  late final TimelineClip b;
  int drops = 0;
  double? rawEdge;
  _Scene() {
    tl.sources.add(
      MediaSource(
        path: 'v.mp4',
        name: 'v',
        kind: ClipKind.video,
        w: 1080,
        h: 1920,
        duration: 20,
      ),
    );
    m = TimelineClip(
      id: tl.nextId(),
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 2,
      offset: 0,
      track: 1,
    );
    b = TimelineClip(
      id: tl.nextId(),
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 4,
      offset: 3,
      track: 0,
    );
    tl.clips.addAll([m, b]);
  }
}

Future<_Scene> _pump(WidgetTester t, {bool snap = true}) async {
  t.view.physicalSize = const Size(1200, 700);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final scene = _Scene();
  final scroll = ScrollController();
  final playhead = ValueNotifier<double>(0);
  addTearDown(scroll.dispose);
  addTearDown(playhead.dispose);
  late StateSetter refresh;
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: StatefulBuilder(
            builder: (context, set) {
              refresh = set;
              return TimelineEditor(
                timeline: scene.tl,
                thumbs: <int, List<Uint8List>>{},
                selectedId: scene.m.id,
                playhead: playhead,
                pxPerSec: _pps,
                trackScale: 1,
                scrollController: scroll,
                onSelect: (_) {},
                onSeek: (_) {},
                // 跟編輯器的 _trimClip 同一套貼齊：原始邊緣累加、再吸
                onTrim: (id, d, left) {
                  final c = scene.tl.clips.firstWhere((c) => c.id == id);
                  final raw = (scene.rawEdge ?? (left ? c.offset : c.end)) + d;
                  scene.rawEdge = raw;
                  final e = snap
                      ? scene.tl.snapTrimEdge(c, raw, _pps, fromLeft: left)
                      : raw;
                  if (!left) {
                    refresh(() => c.trimEnd = c.trimStart + (e - c.offset));
                  }
                },
                onTrimEnd: () => scene.rawEdge = null,
                onDrop: (id, offset, track, insert) {
                  scene.drops++;
                  final c = scene.tl.clips.firstWhere((c) => c.id == id);
                  c.offset = offset;
                  c.track = track;
                },
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
                snapEnabled: snap,
                extraTracks: 0,
                wmLabel: '',
                wmSelected: false,
              );
            },
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return scene;
}

/// 畫面上的對齊線（key＝snap-guide-秒數）
Finder _guides() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('snap-guide-'),
);

double _clipLeft(WidgetTester t, TimelineClip c) =>
    t.getRect(find.byKey(ValueKey('clip${c.id}'))).left;

void main() {
  testWidgets('拖曳：頭切齊別軌素材的頭、尾切齊它的尾都畫線；沒切齊、放手都不畫', (t) async {
    final s = await _pump(t);
    expect(_guides(), findsNothing);
    final bLeft = _clipLeft(t, s.b);
    final bRight = t.getRect(find.byKey(ValueKey('clip${s.b.id}'))).right;
    final g = await t.startGesture(
      t.getCenter(find.byKey(ValueKey('clip${s.m.id}'))),
    );
    // M 的頭想到 2.9 秒：吸到 B 的頭（3 秒）
    await g.moveBy(const Offset(2.9 * _pps, 0));
    await t.pump();
    expect(_guides(), findsOneWidget, reason: 'M 的頭切齊 B 的頭');
    expect(t.getCenter(_guides()).dx, closeTo(bLeft, 1.0));
    // M 的頭想到 5.1 秒：尾巴吸到 B 的尾（7 秒），線在 B 的尾巴
    await g.moveBy(const Offset(2.2 * _pps, 0));
    await t.pump();
    expect(_guides(), findsOneWidget, reason: 'M 的尾切齊 B 的尾');
    expect(t.getCenter(_guides()).dx, closeTo(bRight, 1.0));
    // 遠離所有錨點：不畫
    await g.moveBy(const Offset(4.0 * _pps, 0));
    await t.pump();
    expect(_guides(), findsNothing);
    await g.up();
    await t.pumpAndSettle();
    expect(s.drops, 1);
    expect(_guides(), findsNothing, reason: '放手之後收掉');
    expect(t.takeException(), isNull);
  });

  testWidgets('磁吸關掉：手指停在沒對齊的地方就不畫', (t) async {
    final s = await _pump(t, snap: false);
    final g = await t.startGesture(
      t.getCenter(find.byKey(ValueKey('clip${s.m.id}'))),
    );
    await g.moveBy(const Offset(2.9 * _pps, 0));
    await t.pump();
    expect(_guides(), findsNothing);
    await g.up();
    await t.pumpAndSettle();
  });

  testWidgets('拉修剪把手：尾巴切齊別軌素材的頭就畫線，放手收掉', (t) async {
    final s = await _pump(t);
    final handles = find.byIcon(Icons.drag_indicator);
    expect(handles, findsNWidgets(2), reason: '選取中的 M 左右各一顆把手');
    final right = t.getCenter(handles.at(0)).dx > t.getCenter(handles.at(1)).dx
        ? handles.at(0)
        : handles.at(1);
    final g = await t.startGesture(t.getCenter(right));
    // 尾巴想到 2.93 秒：吸到 B 的頭（3 秒）
    await g.moveBy(const Offset(0.93 * _pps, 0));
    await t.pump();
    expect(s.m.end, closeTo(3, 1e-9));
    expect(_guides(), findsOneWidget);
    expect(t.getCenter(_guides()).dx, closeTo(_clipLeft(t, s.b), 1.0));
    await g.up();
    await t.pumpAndSettle();
    expect(_guides(), findsNothing);
    expect(t.takeException(), isNull);
  });
}
