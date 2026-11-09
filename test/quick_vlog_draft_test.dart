// 快速 Vlog 的草稿：「每段」秒數跟著草稿存，從草稿夾開回來時間軸底下
// 照樣有「每段 N 秒」、緊接照樣開著；改每段＝每一段都改（個別改過的也一起，
// 使用者 11-08「全部改成 0.5 秒一個」），改完的秒數存回草稿。
//
// 一個檔只放一支會寫草稿的編輯頁測試（理由見 draft_cover_harness.dart：
// DraftStore 的存檔佇列是靜態的，跨測試會排不到）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/theme.dart';

import 'draft_cover_harness.dart';
import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('草稿開回來：每段照草稿；改每段連自訂段一起改、存回草稿', (t) async {
    final native = CoverNative(binding);
    await native.install(t);
    const id = 'vlog-draft';
    final path = native.source.path;
    final draft = <String, dynamic>{
      'sources': [
        MediaSource(
          path: path,
          name: 'a',
          kind: ClipKind.video,
          duration: 10,
          w: 320,
          h: 240,
        ).toJson(),
        MediaSource(
          path: path,
          name: 'b',
          kind: ClipKind.video,
          duration: 6,
          w: 320,
          h: 240,
        ).toJson(),
      ],
      'clips': [
        // 跟著每段（3 秒）走
        TimelineClip(
          id: 1,
          sourceIndex: 0,
          trimStart: 3.5,
          trimEnd: 6.5,
          offset: 0,
          track: 0,
        ).toJson(),
        // 個別改成 4 秒
        TimelineClip(
          id: 2,
          sourceIndex: 1,
          trimStart: 1,
          trimEnd: 5,
          offset: 3,
          track: 0,
        ).toJson(),
      ],
      'vlogSec': 3.0,
    };
    await t.pumpWidget(editorApp(VideoEditorScreen(draftId: id, draft: draft)));
    await settle(t);

    expect(
      t.widget<Text>(find.byKey(const ValueKey('vlog-bar-label'))).data,
      '每段',
    );
    expect(
      t.widget<Text>(find.byKey(const ValueKey('vlog-bar-sec'))).data,
      '3',
      reason: '每段要照草稿存的',
    );
    final tidy = t.widget<Icon>(
      find.descendant(
        of: find.ancestor(of: find.text('緊接'), matching: find.byType(InkWell)),
        matching: find.byType(Icon),
      ),
    );
    expect(tidy.color, kSelect, reason: '快速 Vlog 的草稿開回來也緊接');

    final s = t.widget<Slider>(find.byKey(const ValueKey('vlog-bar-slider')));
    s.onChangeStart?.call(s.value);
    s.onChanged!(2);
    s.onChangeEnd!(2);
    await settle(t, 6);

    final lane = modelOf(t).onTrack(0);
    expect(lane[0].length, closeTo(2, 1e-6));
    expect(lane[1].length, closeTo(2, 1e-6), reason: '個別改過的也一起改');
    expect(lane[1].trimStart, closeTo(2, 1e-6), reason: '中心（3）不動');
    expect(lane[1].offset, closeTo(2, 1e-6), reason: '整軌接齊');

    final saved = await pollUntil(
      t,
      () => DraftStore.load(id),
      (v) => v?['vlogSec'] == 2.0,
    );
    expect(saved?['vlogSec'], 2.0, reason: '改過的每段要存回草稿');
    await native.dispose(t);
  });
}
