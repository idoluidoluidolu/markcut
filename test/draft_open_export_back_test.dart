// 迴歸：匯出成功之後按返回離開編輯頁，「編輯中」的登記
//（DraftStore.holdOpen）從來沒有解除。
//
// 匯出成功過的專案離開時不再問留不留草稿（_handleBack 的 _exportedOk）：
// 補存一次（force）就 pop。那次補存一開頭就登記「編輯中」，這條路卻沒有
// 解除；併批計時器還在跑的話，dispose 的補存又登記一次。結果整場
// hasOpenDrafts 都是 true——工作檔清掃（WorkFiles.sweep）每次都跳過、
// 「容量與清理」按了也什麼都不清。
//
// 同一類的另一條：draft_open_export_home_test（匯出完按「回主畫面」）
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/draft_store.dart';

import 'draft_cover_harness.dart';
import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('匯出成功後按返回離開：「編輯中」要解除，最後的補存與封面照樣落地', (t) async {
    final native = CoverNative(binding);
    await native.install(t);
    const id = 'export-back';
    final nav = await pushEditor(
      t,
      VideoEditorScreen(draftId: id, draft: native.draft()),
    );
    expect(find.byType(VideoEditorScreen), findsOneWidget);
    expect(DraftStore.hasOpenDrafts, isTrue, reason: '編輯中的草稿要登記，清理才不會碰它');

    await exportSucceeds(t);
    await t.tap(find.text('繼續編輯'));
    await settle(t, 5);
    // 返回先一格一格退分頁：匯出 → 浮水印 → 剪輯
    for (var i = 0; i < 2; i++) {
      unawaited(nav.currentState!.maybePop());
      await settle(t, 5);
    }
    expect(find.byType(VideoEditorScreen), findsOneWidget, reason: '還在剪輯分頁');
    final before = await pollUntil(
      t,
      () => DraftStore.thumb(id),
      (v) => v != null,
    );
    expect(before, isNotNull, reason: '匯出成功那次補存的封面');

    // 最後一個改動還在併批計時器裡就按返回：返回那次補存（force）與
    // dispose 的補存都會跑
    editorOf(t).onToggleWmVisible!();
    unawaited(nav.currentState!.maybePop());
    await settle(t, 25);
    expect(
      find.byType(VideoEditorScreen),
      findsNothing,
      reason: '匯出過的專案不問留不留，直接離開',
    );
    expect(
      DraftStore.hasOpenDrafts,
      isFalse,
      reason: '離開了還登記著「編輯中」：工作檔清掃與「容量與清理」整場都被擋住',
    );

    final saved = await pollUntil(
      t,
      () => DraftStore.load(id),
      (v) => v?['wmHidden'] == true,
    );
    expect(saved?['wmHidden'], isTrue, reason: '離開前最後那個改動要補存進去');
    final after = await pollUntil(
      t,
      () => DraftStore.thumb(id),
      (v) => v != null && v != before,
    );
    expect(after, isNot(before), reason: '最後那次補存的封面（浮水印關掉了）要換上去');
    await settle(t, 10);
    expect(DraftStore.hasOpenDrafts, isFalse, reason: '背景的補存與封面跑完也不能再登記回去');
    await native.dispose(t);
  });
}
