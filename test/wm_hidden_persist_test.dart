// 迴歸守門（稽核 #10）：浮水印「隱藏」要進草稿、也要進復原快照。
//
// 點浮水印軌標籤＝關掉浮水印，使用者被告知「預覽和匯出一起關」；但這個
// 旗標以前只活在記憶體：不進 _projectJson（重開草稿浮水印回來、也跟著
// 匯出）、不進 _snapshot（跟軌道的隱藏不同調）、切換本身也不排存草稿
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/draft_store.dart';

import 'editor_harness.dart';

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('隱藏浮水印 → 草稿落地帶著 wmHidden → 從草稿開回來還是隱藏', (t) async {
    const id = 'wm-hidden-draft';
    await t.pumpWidget(
      editorApp(const VideoEditorScreen(blank: true, draftId: id)),
    );
    await settle(t, 5);
    expect(editorOf(t).wmHidden, isFalse);

    editorOf(t).onToggleWmVisible!();
    await settle(t, 3);
    expect(editorOf(t).wmHidden, isTrue);

    // 切換本身要排存草稿（併批 900ms）：不能靠之後別的編輯順便存
    Map<String, dynamic>? saved;
    for (var i = 0; i < 100 && saved?['wmHidden'] != true; i++) {
      await settle(t, 3);
      await t.runAsync(() async => saved = await DraftStore.load(id));
    }
    expect(saved?['wmHidden'], isTrue, reason: '草稿要記到隱藏');

    // 換一頁再從草稿開回來
    await t.pumpWidget(const SizedBox());
    await settle(t, 5);
    await t.pumpWidget(
      editorApp(VideoEditorScreen(draft: saved, draftId: id)),
    );
    await settle(t, 10);
    expect(editorOf(t).wmHidden, isTrue, reason: '重開草稿浮水印不能又回來');
    await settle(t, 80);
  });

  testWidgets('復原快照帶著隱藏狀態：上一步退回沒隱藏、重做回到隱藏', (t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await settle(t, 5);
    // 拍一份快照（修剪起手就是拍快照）：那時候還沒隱藏
    editorOf(t).onTrimStart!();
    await settle(t, 3);
    editorOf(t).onToggleWmVisible!();
    await settle(t, 3);
    expect(editorOf(t).wmHidden, isTrue);

    await t.tap(undoButton());
    await settle(t, 6);
    expect(editorOf(t).wmHidden, isFalse, reason: '快照拍的時候還沒隱藏：退回去');

    await t.tap(redoButton());
    await settle(t, 6);
    expect(editorOf(t).wmHidden, isTrue, reason: '重做回到隱藏');
    await settle(t, 80);
  });
}
