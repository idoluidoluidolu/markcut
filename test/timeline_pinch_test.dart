import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/widgets/timeline_editor.dart';

/// 雙指縮放時間軸時不能誤觸素材（使用者回報：常常不小心拖到、長按到）。
///
/// 規則：第二根手指一落下就是捏合——進行中的拿起／長按作廢、素材留在
/// 原位、之後落下的手指不開任何單指手勢；全部抬起再冷卻 150ms 才恢復。

/// 兩條軌：track 0 一段 28.5 秒的影片、track 1 一張 3 秒的圖片
TimelineModel _model() {
  final tl = TimelineModel();
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

/// 回呼記錄：測試只看「有沒有被叫到、帶什麼」
class _Spy {
  int selected = -1;
  final drops = <int>[]; // onDrop 的片段 id
  final longPresses = <int>[]; // onLongPressClip 的片段 id
  final emptyLongPresses = <int>[]; // onLongPressEmpty 的軌
  final lifts = <bool>[]; // onLiftChanged 序列
  final seeks = <double>[];
}

Widget _editor(
  TimelineModel tl,
  _Spy spy,
  ScrollController scroll,
  ValueNotifier<double> playhead, {
  bool pinching = false,
}) {
  return TimelineEditor(
    timeline: tl,
    thumbs: <int, List<Uint8List>>{},
    selectedId: spy.selected,
    playhead: playhead,
    pxPerSec: 30,
    trackScale: 1,
    scrollController: scroll,
    onSelect: (id) => spy.selected = id,
    onSeek: spy.seeks.add,
    onTrim: (_, _, _) {},
    onDrop: (id, _, _, _) => spy.drops.add(id),
    onAddMedia: (_) {},
    onReorderTrack: (_, _) {},
    mutedTracks: const {},
    onToggleMute: (_) {},
    onLongPressClip: (id, _) => spy.longPresses.add(id),
    onLongPressEmpty: (track, _, _) => spy.emptyLongPresses.add(track),
    onLiftChanged: spy.lifts.add,
    pinching: pinching,
    onSelectWm: () {},
    onMoveWm: (_) {},
    onTrimWm: (_, _) {},
    selectedTrack: -1,
    snapEnabled: true,
    extraTracks: 0,
    wmLabel: '',
    wmSelected: false,
  );
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SizedBox(height: 500, child: child)),
);

/// 影片素材上一個在畫面裡的點
Offset _onVideo(WidgetTester t, TimelineModel tl) {
  final r = t.getRect(find.byKey(ValueKey('clip${tl.clips[0].id}')));
  return Offset(r.left + 200, r.center.dy);
}

/// 最上面那條空軌上的一個點（捏合的第二指常落在這種空白處）：
/// 刻度尺 22 + 間距 10 + 半個軌高 27；x 落在時間 0 之後的軌道帶上
Offset _onEmptyRow(WidgetTester t) {
  final r = t.getRect(find.byType(TimelineEditor));
  return Offset(r.left + 550, r.top + 22 + 10 + 27);
}

void main() {
  setUpAll(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(1200, 2200);
    v.devicePixelRatio = 1.0;
  });

  late TimelineModel tl;
  late _Spy spy;
  late ScrollController scroll;
  late ValueNotifier<double> playhead;

  setUp(() {
    tl = _model();
    spy = _Spy();
    scroll = ScrollController();
    playhead = ValueNotifier<double>(0);
  });

  tearDown(() {
    scroll.dispose();
    playhead.dispose();
  });

  Future<void> pumpEditor(WidgetTester t) async {
    await t.pumpWidget(_host(_editor(tl, spy, scroll, playhead)));
    await t.pumpAndSettle();
  }

  /// 新契約（使用者指定）：片段要先選起來才搬得動。點一下選取，
  /// 再重畫一次讓新的 selectedId 傳進去
  Future<void> selectFirstClip(WidgetTester t) async {
    await t.tapAt(_onVideo(t, tl));
    await t.pumpAndSettle();
    await pumpEditor(t);
    expect(spy.selected, tl.clips[0].id);
    spy.lifts.clear();
  }

  testWidgets('第一指按在素材上、第二指落下後捏合：不拖曳、不長按、不選取', (t) async {
    await pumpEditor(t);
    final a = await t.startGesture(_onVideo(t, tl));
    await t.pump(const Duration(milliseconds: 40));
    final b = await t.startGesture(_onEmptyRow(t));
    await t.pump(const Duration(milliseconds: 20));
    // 兩指慢慢張開，前後超過 450ms（素材長按）與 500ms（空白處長按）
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.pump(const Duration(milliseconds: 300));
    await b.up();
    await t.pump(const Duration(milliseconds: 20));
    await a.up();
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 200));

    expect(spy.drops, isEmpty, reason: '素材不能被搬走');
    expect(spy.longPresses, isEmpty, reason: '不能開素材的長按選單');
    expect(spy.emptyLongPresses, isEmpty, reason: '不能開空白處的貼上選單');
    expect(spy.selected, -1, reason: '捏合不能順便選到素材');
    expect(spy.lifts.contains(true), isFalse, reason: '不能告訴父層在拖曳');
    expect(tl.clips[0].offset, 0, reason: '資料要留在原位');
  });

  testWidgets('第一指已經拖起素材、第二指才落下：當場放回原位、放開不寫回', (t) async {
    await pumpEditor(t);
    await selectFirstClip(t);
    final a = await t.startGesture(_onVideo(t, tl));
    await t.pump(const Duration(milliseconds: 20));
    await a.moveBy(const Offset(12, 0)); // 超過 8px 的武裝門檻＝真的在拖
    await t.pump(const Duration(milliseconds: 20));
    expect(spy.lifts, [true], reason: '單指拖曳先成立');

    final b = await t.startGesture(_onEmptyRow(t));
    await t.pump(const Duration(milliseconds: 20));
    expect(spy.lifts, [true, false], reason: '第二指落下的當下就要放回去');

    for (var i = 0; i < 4; i++) {
      await a.moveBy(const Offset(-15, 0));
      await b.moveBy(const Offset(15, 0));
      await t.pump(const Duration(milliseconds: 50));
    }
    await a.up();
    await b.up();
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 200));

    expect(spy.drops, isEmpty, reason: '放開不能寫回新位置');
    expect(tl.clips[0].offset, 0);
    expect(spy.lifts, [true, false], reason: '放開後不能再冒出拖曳通知');
  });

  testWidgets('錨定在素材上不動的那根手指，按滿 450ms 也不開長按選單', (t) async {
    await pumpEditor(t);
    final a = await t.startGesture(_onVideo(t, tl));
    await t.pump(const Duration(milliseconds: 30));
    final b = await t.startGesture(_onEmptyRow(t));
    await t.pump(const Duration(milliseconds: 30));
    // 只有第二指在動（單手捏合常見：拇指定住、食指張開）
    for (var i = 0; i < 8; i++) {
      await b.moveBy(const Offset(8, 0));
      await t.pump(const Duration(milliseconds: 100));
    }
    await b.up();
    await a.up();
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 200));

    expect(spy.longPresses, isEmpty);
    expect(spy.selected, -1);
    expect(spy.drops, isEmpty);
  });

  testWidgets('兩指全部離開後 150ms 內的點擊不算；冷卻過了照常選取', (t) async {
    await pumpEditor(t);
    final a = await t.startGesture(_onVideo(t, tl));
    await t.pump(const Duration(milliseconds: 30));
    final b = await t.startGesture(_onEmptyRow(t));
    await t.pump(const Duration(milliseconds: 30));
    await b.up();
    await t.pump(const Duration(milliseconds: 30));
    await a.up();
    await t.pump(const Duration(milliseconds: 30));

    // 抬手的餘波：冷卻中的點擊
    await t.tapAt(_onVideo(t, tl));
    await t.pump(const Duration(milliseconds: 20));
    expect(spy.selected, -1, reason: '冷卻中不算點擊');

    await t.pump(const Duration(milliseconds: 200));
    await t.tapAt(_onVideo(t, tl));
    await t.pumpAndSettle();
    expect(spy.selected, tl.clips[0].id, reason: '冷卻過了要恢復正常');
  });

  testWidgets('父層的 pinching 旗標翻起來時，拿起中的素材要放回去', (t) async {
    var pinching = false;
    late StateSetter setLocal;
    await t.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, set) {
            setLocal = set;
            return _editor(tl, spy, scroll, playhead, pinching: pinching);
          },
        ),
      ),
    );
    await t.pumpAndSettle();

    // 先選起來才搬得動（新契約）
    await t.tapAt(_onVideo(t, tl));
    await t.pumpAndSettle();
    setLocal(() {});
    await t.pump();
    spy.lifts.clear();

    final a = await t.startGesture(_onVideo(t, tl));
    await t.pump(const Duration(milliseconds: 20));
    await a.moveBy(const Offset(12, 0));
    await t.pump(const Duration(milliseconds: 20));
    expect(spy.lifts, [true]);

    // 父層在分頁層級數到第二指（例如落在時間軸外的空白處）
    setLocal(() => pinching = true);
    await t.pump();
    expect(spy.lifts, [true, false], reason: '旗標一翻就放回去');

    await a.moveBy(const Offset(40, 0));
    await t.pump(const Duration(milliseconds: 20));
    await a.up();
    await t.pumpAndSettle();
    expect(spy.drops, isEmpty);
    expect(tl.clips[0].offset, 0);

    // 捏合結束、冷卻過後，單指拖曳恢復
    setLocal(() => pinching = false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    final c = await t.startGesture(_onVideo(t, tl));
    for (var i = 0; i < 4; i++) {
      await c.moveBy(const Offset(15, 0));
      await t.pump(const Duration(milliseconds: 30));
    }
    await c.up();
    await t.pumpAndSettle();
    expect(spy.drops, [tl.clips[0].id], reason: '單指拖曳要恢復');
  });

  testWidgets('未選取的片段拖不動：只會被選起來，不會被搬走', (t) async {
    await pumpEditor(t);
    final g = await t.startGesture(_onVideo(t, tl));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(15, 0));
      await t.pump(const Duration(milliseconds: 30));
    }
    await g.up();
    await t.pumpAndSettle();
    expect(spy.drops, isEmpty, reason: '沒選起來就不該搬動');
    expect(
      spy.lifts,
      isNot(contains(true)),
      reason: '父層不該以為使用者在搬素材（收尾的 false 無所謂）',
    );
    expect(spy.selected, tl.clips[0].id, reason: '這一下當成選取');
    expect(tl.clips[0].offset, 0);
  });

  testWidgets('回歸：選起來之後單指拖曳搬得動、按住 450ms 照樣開長按選單', (t) async {
    await pumpEditor(t);
    await selectFirstClip(t);
    final a = await t.startGesture(_onVideo(t, tl));
    for (var i = 0; i < 4; i++) {
      await a.moveBy(const Offset(15, 0));
      await t.pump(const Duration(milliseconds: 30));
    }
    await a.up();
    await t.pumpAndSettle();
    expect(spy.drops, [tl.clips[0].id]);
    expect(spy.lifts, [true, false]);

    final b = await t.startGesture(_onVideo(t, tl));
    await t.pump(const Duration(milliseconds: 500));
    expect(spy.longPresses, [tl.clips[0].id], reason: '長按選單要照常');
    await b.up();
    await t.pumpAndSettle();
  });
}
