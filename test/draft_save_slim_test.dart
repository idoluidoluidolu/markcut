// 自動存檔瘦身：封面另外存成一個檔，草稿內容裡不再塞一份（以前每個編輯
// 動作的自動存檔都把一張 720p 封面多寫一遍，草稿夾也沒有人讀那一份）；
// 同時寫一份很小的檔案清單（草稿夾算容量、刪草稿連帶清理只讀它）
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

  testWidgets('草稿內容不帶封面、檔案清單跟著存', (t) async {
    const id = 'slim-draft';
    await t.pumpWidget(
      editorApp(const VideoEditorScreen(blank: true, draftId: id)),
    );
    await settle(t, 5);
    // 隨便改一個會存草稿的東西（隱藏浮水印會排一次併批存檔）
    editorOf(t).onToggleWmVisible!();
    Map<String, dynamic>? saved;
    Set<String>? refs;
    for (var i = 0; i < 100 && (saved?['wmHidden'] != true || refs == null); i++) {
      await settle(t, 3);
      await t.runAsync(() async {
        saved = await DraftStore.load(id);
        refs = await DraftStore.refs(id);
      });
    }
    expect(saved?['wmHidden'], isTrue, reason: '草稿要存下來');
    expect(saved!.containsKey('thumb'), isFalse, reason: '封面另外存，不進內容');
    expect(saved!.containsKey('thumbAspect'), isFalse);
    expect(refs, isNotNull, reason: '檔案清單要跟著存（空專案＝空清單）');
    expect(refs, isEmpty);
    await settle(t, 80);
  });
}
