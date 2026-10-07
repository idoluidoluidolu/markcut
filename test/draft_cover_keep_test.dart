// 迴歸（實機回報：「草稿沒有顯示縮圖」）：打開有封面的舊草稿，第一次
// 自動存檔就把封面刪了。
//
// 編輯器一打開，手上還沒有這一場畫的封面（背景要等存完才畫），存檔帶的
// 封面是 null——而 null 在 DraftStore 的意思是「這份專案沒有封面了」，
// 存著的那張被刪掉、索引記成沒有封面。背景那張只要沒掛上去（以前每一張
// 都沒掛上去，見 draft_cover_autosave_test），草稿就從此只剩灰底，而且
// 因為剛存過、排在草稿清單最前面。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/draft_store.dart';

import 'draft_cover_harness.dart';
import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('打開有封面的草稿：新封面畫出來之前的自動存檔不能把舊的刪掉', (t) async {
    // 一格都抽不到：這一場畫不出新封面（素材在雲端、原生忙不過來）
    final native = CoverNative(binding, frames: false);
    await native.install(t);
    const id = 'old-cover';
    final draft = native.draft();
    final old = base64Encode(solidPng(10, 200, 10, size: 16));
    await t.runAsync(
      () => DraftStore.save(
        id,
        jsonEncode(draft),
        thumb: old,
        thumbAspect: 1.5,
        clipCount: 1,
      ),
    );
    await t.pumpWidget(editorApp(VideoEditorScreen(draftId: id, draft: draft)));
    await settle(t);
    editorOf(t).onToggleWmVisible!();
    final saved = await pollUntil(
      t,
      () => DraftStore.load(id),
      (v) => v?['wmHidden'] == true,
    );
    expect(saved?['wmHidden'], isTrue, reason: '草稿要先存下來');
    // 背景那一輪封面跑完（畫不出來）
    await settle(t, 30);
    String? thumb;
    await t.runAsync(() async => thumb = await DraftStore.thumb(id));
    expect(thumb, old, reason: '畫不出新的就留著舊的，不能存一次就變灰底');
    final meta = await draftMetaOf(t, id);
    expect(meta?.hasThumb, isTrue);
    expect(meta?.thumbAspect, 1.5, reason: '留著舊封面就留著它的比例');
    await native.dispose(t);
  });
}
