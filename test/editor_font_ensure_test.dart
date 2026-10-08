// 影片編輯器的文字素材直接畫字（不經過 WatermarkLayer），iOS 合成的烘圖也
// 只讀手機裡的字型：編輯器自己要去拿文字素材用到的下載字型，不然重開 App
// 打開草稿，文字素材會一直是後備字（審查抓到的）
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/services/diagnostics.dart';
import 'package:markcut/services/font_store.dart';

import 'editor_harness.dart';

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });
  late FakeComp comp;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Diag.reset();
    // 測試環境沒有真的原生 UiKitView：合成畫面走 Texture
    Diag.playerLayer.value = false;
    comp = FakeComp(TestWidgetsFlutterBinding.ensureInitialized())..install();
  });
  tearDown(() {
    comp.uninstall();
    FontStore.instance.debugReset();
  });

  testWidgets('文字素材用了還沒載入的下載字型：編輯器自己去拿', (t) async {
    final bytes = Uint8List.fromList(List.generate(3000, (i) => i & 0xff));
    final loads = <String>[];
    var requests = 0;
    FontStore.instance.debugReset(
      client: () => MockClient.streaming((req, _) async {
        requests++;
        return http.StreamedResponse(Stream.value(bytes), 200);
      }),
      load: (family, _) async => loads.add(family),
      catalog: {
        'PopGothic': DownloadFont(
          file: 'fonts/PopGothic.ttf',
          bytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          previewFamily: 'PopGothicLabel',
        ),
      },
    );
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((m) {
      m.sources.add(
        MediaSource(
          path: '',
          name: '阿明',
          kind: ClipKind.text,
          duration: 3600,
          textStyle: TextMark(text: '阿明', fontFamily: 'PopGothic'),
        ),
      );
      m.clips.add(
        TimelineClip(
          id: 1,
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 3,
          offset: 0,
          track: 0,
        ),
      );
      m.ensureIdAbove(1);
    });
    await tick(t, 15);
    expect(loads, ['PopGothic']);
    expect(requests, 1, reason: '同一款只下載一次');
    expect(FontStore.instance.isReady('PopGothic'), isTrue);
  });
}
