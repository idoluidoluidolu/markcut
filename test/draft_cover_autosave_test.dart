// 迴歸（實機回報：「草稿沒有顯示縮圖」——個人中心最新的幾份草稿只剩
// 灰底＋膠卷圖示）。
//
// 封面是存完草稿才在背景畫的（_drainDraftCovers）。以前畫好之後拿
// _tlVersion 比對「存檔之後時間軸有沒有變」，但它是預覽熱路徑的快取
// 版本號：每次 setState 都加一，而且 _saveDraft 存完緊接著叫的
// _compRefreshIfChanged 在合成播放器開著（預設）時一定加一——每一張畫好
// 的封面都被當成過期丟掉，自動存檔的草稿從來存不到封面。
//
// 同一組的另外兩支：draft_cover_keep_test（舊封面不能被存檔刪掉）、
// draft_cover_leave_test（「保留草稿」離開時封面照樣落地）
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/draft_store.dart';

import 'draft_cover_harness.dart';
import 'editor_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('合成播放器開著：自動存檔之後影片草稿要有封面', (t) async {
    final native = CoverNative(binding);
    await native.install(t);
    const id = 'auto-cover';
    await t.pumpWidget(
      editorApp(VideoEditorScreen(draftId: id, draft: native.draft())),
    );
    await settle(t);
    // 隨便改一個會排併批存檔的東西：存完緊接著就是 _compRefreshIfChanged
    editorOf(t).onToggleWmVisible!();
    final saved = await pollUntil(
      t,
      () => DraftStore.load(id),
      (v) => v?['wmHidden'] == true,
    );
    expect(saved?['wmHidden'], isTrue, reason: '草稿要先存下來');
    final thumb = await pollUntil(
      t,
      () => DraftStore.thumb(id),
      (v) => v != null,
    );
    expect(native.calls, contains('cover'), reason: '封面那一格真的抽了');
    expect(
      thumb,
      isNotNull,
      reason: '畫好的封面要掛上去：不能因為存完之後 setState／重組檢查動了版本號就丟掉',
    );
    final meta = await draftMetaOf(t, id);
    expect(meta?.hasThumb, isTrue);
    expect(meta?.thumbAspect, isNotNull);
    await native.dispose(t);
  });
}
