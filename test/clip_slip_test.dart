// 換段（slip）：使用者要的「時間軸影片素材要能調整片段」——片段在時間軸
// 上的長度跟位置都不動，換成原片裡的另一段。
//
//   1. 選一段影片 → 工具列「換段」→ 整支原片的縮圖帶，框＝用到的那一截
//   2. 左右拖：框跟著走，放手才套用（trimStart／trimEnd 一起平移、長度
//      不變、offset 不變）；拖過頭會停在原片的頭尾
//   3. 點一下選起點，大預覽即時顯示所選段落開頭
//   4. 換完一步「上一步」就回來；打開看看就關掉不算一步
//   5. 不是影片（文字…）或已經用到整支影片：按鈕灰掉、點了講為什麼
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/widgets/slip_strip.dart';

import 'editor_harness.dart';

/// 一支 20 秒的影片，片段用 2～6 秒那一截，擺在時間軸 1 秒處；
/// 再一段文字（換段點不了它）
void _fill(TimelineModel m) {
  m.sources.add(
    MediaSource(
      path: '/v.mp4',
      name: 'v',
      kind: ClipKind.video,
      duration: 20,
      // 給工作檔＝不探 HDR、不碰檔案系統
      workPath: '/v.work.mp4',
    ),
  );
  m.clips.add(
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 2,
      trimEnd: 6,
      offset: 1,
      track: 0,
    ),
  );
  m.sources.add(
    MediaSource(path: '', name: 'hi', kind: ClipKind.text, duration: 3600),
  );
  m.clips.add(
    TimelineClip(
      id: 2,
      sourceIndex: 1,
      trimStart: 0,
      trimEnd: 3,
      offset: 0,
      track: 3,
    ),
  );
  m.ensureIdAbove(2);
}

/// 開空白編輯器、塞時間軸，等合成組起來（併批 350ms，走假時間）
Future<void> _open(WidgetTester t, FakeComp comp) async {
  await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
  await tick(t, 5);
  VideoEditorScreen.debugTimeline!(_fill);
  await tick(t, 15);
  expect(comp.builds, 1, reason: '合成播放器要組起來');
}

Finder get _strip => find.byKey(const ValueKey('slip-strip'));
void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });
  // 假的原生合成播放器：預覽走合成那條路（跟實機一樣），不開 media_kit
  // 的單支播放器（測試主機沒有 libmpv）；也拿它數「換段有沒有重組合成」
  late FakeComp comp;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.reset();
    // 測試環境沒有真的原生 UiKitView：合成畫面走 Texture
    Diag.playerLayer.value = false;
    comp = FakeComp(TestWidgetsFlutterBinding.ensureInitialized())..install();
  });
  tearDown(() => comp.uninstall());

  testWidgets('選影片 → 換段：拖框換一段，長度與位置不變；上一步回來', (t) async {
    await _open(t, comp);
    await t.tapAt(t.getCenter(clipBlock(1)));
    await settle(t, 6);
    await t.tap(find.text('換段'));
    await settle(t, 6);
    expect(_strip, findsOneWidget, reason: '沒有開出換段的縮圖帶');
    expect(find.text('開頭 00:02.00'), findsOneWidget);
    expect(find.textContaining('結尾'), findsNothing);
    expect(
      t.getSize(find.byKey(const ValueKey('slip-preview-start'))).height,
      greaterThan(350),
    );
    // 打開看看還沒動：不是一個編輯步驟
    expect(undoEnabled(t), isFalse);

    // 往右拖四分之一條（整條＝20 秒）：框往後移，放手套用、重組合成
    final builds = comp.builds;
    final w = t.getSize(_strip).width;
    await t.drag(_strip, Offset(w / 4, 0));
    await settle(t, 6);
    // 合成的重組是併批的（350ms），而且等預覽跳到這段開頭的那次 seek 收完
    // 才做（手勢中不換畫面）：假時間走一段
    await tick(t, 40);
    final c = clipOf(t, 1);
    expect(c.trimStart, greaterThan(4), reason: '框沒有跟著往後');
    expect(comp.builds, greaterThan(builds), reason: '換段沒有重組合成');
    expect(c.trimEnd - c.trimStart, closeTo(4, 1e-9), reason: '長度不能變');
    expect(c.offset, 1, reason: '在時間軸上的位置不能變');
    expect(
      find.text('開頭 ${_t(c.trimStart)}'),
      findsOneWidget,
      reason: '起點預覽的時間沒跟著換',
    );

    // 往右拖過頭：停在原片尾巴（16～20）
    await t.drag(_strip, Offset(w, 0));
    await settle(t, 6);
    expect(clipOf(t, 1).trimStart, closeTo(16, 1e-9));
    expect(clipOf(t, 1).trimEnd, closeTo(20, 1e-9));

    // 拖到最左邊，夾在原片起點＝0～4。
    await t.drag(_strip, Offset(-w, 0));
    await settle(t, 6);
    expect(clipOf(t, 1).trimStart, closeTo(0, 1e-9));
    expect(clipOf(t, 1).trimEnd, closeTo(4, 1e-9));

    // 關掉表、上一步：回到原本那一截
    await t.tap(find.text('完成'));
    await settle(t, 6);
    expect(undoEnabled(t), isTrue);
    await t.tap(undoButton());
    await settle(t, 6);
    expect(clipOf(t, 1).trimStart, closeTo(2, 1e-9));
    expect(clipOf(t, 1).trimEnd, closeTo(6, 1e-9));
    expect(t.takeException(), isNull);
    await settle(t, 40);
  });

  testWidgets('文字片段：換段灰掉，點了說只有影片可以換段', (t) async {
    await _open(t, comp);
    await t.tapAt(t.getCenter(clipBlock(2)));
    await settle(t, 6);
    await t.tap(find.text('換段'));
    await settle(t, 4);
    expect(_strip, findsNothing);
    expect(find.text('只有影片可以換段'), findsOneWidget);
    expect(find.byType(SlipStrip), findsNothing);
    await settle(t, 80);
    expect(t.takeException(), isNull);
  });
}

/// 選段表保留百分之一秒，細調時看得出變化。
String _t(double sec) {
  final d = Duration(milliseconds: (sec * 1000).round());
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s.${((d.inMilliseconds % 1000) ~/ 10).toString().padLeft(2, '0')}';
}
