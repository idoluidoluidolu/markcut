// 迴歸：匯出完在「匯出完成」按「回主畫面」，「編輯中」的登記
//（DraftStore.holdOpen）從來沒有解除。
//
// 匯出成功那一刻會補存一次（force），一開頭就登記「編輯中」；回主畫面
// 走 popUntil，不經過 PopScope／_handleBack，以前也就沒有任何地方解除。
// 結果整場 hasOpenDrafts 都是 true：工作檔清掃與「容量與清理」都被擋住。
//
// 同一類的另一條：draft_open_export_back_test（匯出後按返回離開）
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/draft_store.dart';

import 'draft_cover_harness.dart';
import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('匯出完按「回主畫面」離開：「編輯中」要解除，補存的封面照樣落地', (t) async {
    final native = CoverNative(binding);
    await native.install(t);
    const id = 'export-home';
    await pushEditor(t, VideoEditorScreen(draftId: id, draft: native.draft()));
    expect(find.byType(VideoEditorScreen), findsOneWidget);
    expect(DraftStore.hasOpenDrafts, isTrue, reason: '編輯中的草稿要登記，清理才不會碰它');

    await exportSucceeds(t);
    await t.tap(find.text('回主畫面'));
    await settle(t, 25);
    expect(find.byType(VideoEditorScreen), findsNothing, reason: '回到首頁了');
    expect(
      DraftStore.hasOpenDrafts,
      isFalse,
      reason: '離開了還登記著「編輯中」：工作檔清掃與「容量與清理」整場都被擋住',
    );

    final thumb = await pollUntil(
      t,
      () => DraftStore.thumb(id),
      (v) => v != null,
    );
    expect(thumb, isNotNull, reason: '匯出成功那次補存的封面照樣落地');
    final meta = await draftMetaOf(t, id);
    expect(meta?.hasThumb, isTrue);
    await settle(t, 10);
    expect(DraftStore.hasOpenDrafts, isFalse, reason: '背景的補存與封面跑完也不能再登記回去');
    await native.dispose(t);
  });
}
