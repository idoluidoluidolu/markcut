// 迴歸守門（稽核 #8）：浮水印／貼圖片段（ClipKind.wm）的左把手要能往前
// 長，不是只能縮——文字／馬賽克／圖片本來就可以。
//
// 這幾種素材沒有本體（duration 是假的 3600、trimStart 生下來就是 0），
// 左把手走的是「往前生長」的語意（起點前移、右緣不動）；wm 漏在那張
// 名單外，走到「素材修剪」那條：trimStart 已經是 0，往前一步 clamp 回 0，
// 起點一動也不動。
//
// 同一支測試先拿文字片段當對照組（一直都能往前長），再做浮水印與貼圖
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';

import 'editor_harness.dart';

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 選取 [id]、把左把手往左拖 [px]，回「起點往前了幾秒」
  Future<double> growLeft(WidgetTester t, int id, double px) async {
    await t.tapAt(t.getCenter(clipBlock(id)));
    await settle(t, 6);
    final before = clipOf(t, id).offset;
    await t.drag(handleOf(t, id, left: true), Offset(-px, 0));
    await settle(t, 6);
    return before - clipOf(t, id).offset;
  }

  testWidgets('wm 片段左把手往左拖：起點前移、右緣不動（跟文字片段一樣）', (t) async {
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await settle(t, 5);
    // 文字 2~5（第 0 軌）、浮水印 2~5（第 1 軌）、貼圖 2~5（第 2 軌）
    VideoEditorScreen.debugTimeline!((m) {
      m.sources.add(
        MediaSource(path: '', name: 'hi', kind: ClipKind.text, duration: 3600),
      );
      m.sources.add(
        MediaSource(
          path: '',
          name: '浮水印',
          kind: ClipKind.wm,
          duration: 3600,
          wmStyle: WatermarkSettings()..text = TextMark(text: '@浮水印'),
        ),
      );
      m.sources.add(
        MediaSource(
          path: '',
          name: '貼圖',
          kind: ClipKind.wm,
          duration: 3600,
          isSticker: true,
          wmStyle: WatermarkSettings()
            ..text = TextMark(text: '', enabled: false),
        ),
      );
      for (var i = 0; i < 3; i++) {
        m.clips.add(
          TimelineClip(
            id: i + 1,
            sourceIndex: i,
            trimStart: 0,
            trimEnd: 3,
            offset: 2,
            track: i,
          ),
        );
      }
      m.ensureIdAbove(3);
    });
    await settle(t, 10);
    final r1 = t.getRect(clipBlock(1));
    final pxPerSec = r1.width / 3;
    const px = 60.0;
    final want = px / pxPerSec;

    final textGrew = await growLeft(t, 1, px);
    expect(textGrew, closeTo(want, 0.02), reason: '對照組：文字片段往前長了把手走的量');
    expect(clipOf(t, 1).end, closeTo(5, 1e-6), reason: '右緣不動');

    final wmGrew = await growLeft(t, 2, px);
    expect(wmGrew, closeTo(want, 0.02), reason: '浮水印片段也要往前長，不是釘在原地');
    expect(clipOf(t, 2).end, closeTo(5, 1e-6), reason: '右緣不動');
    expect(clipOf(t, 2).length, closeTo(3 + want, 0.02), reason: '長度＝多出來的那段');

    final stkGrew = await growLeft(t, 3, px);
    expect(stkGrew, closeTo(want, 0.02), reason: '貼圖也是 wm 種類，一樣要能往前長');
    expect(clipOf(t, 3).end, closeTo(5, 1e-6));
    // 讓併批的草稿存檔跑完，別留計時器
    await settle(t, 80);
  });
}
