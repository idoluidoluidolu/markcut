// 選了浮水印，預覽上一定要有琥珀框（10-16 使用者截圖：浮水印分頁 → 文字，
// 預覽上的「買電腦」沒有框）。沒框的路有三條：
//   1. 全域浮水印只有點預覽／點時間軸那條軌才會選；從底下的「浮水印」分頁
//      進來、在面板切「文字」「圖片」、在面板改東西都不會選
//   2. 浮水印素材（＋ → 浮水印）被選著時，預覽完全不畫框（只有貼圖畫）
//   3. 點預覽上的浮水印圖片，選取跟面板一律當成點了文字，框落在文字上
// 這支盯：
//   - 取消選取後點「浮水印」分頁：框回來、是琥珀色、在文字上
//   - 面板切「圖片」框換到圖片，切回「文字」換回來
//   - 分頁裡點空白取消選取，再打字：框回來
//   - 只有圖片沒有文字：進分頁也框得到（落在圖片）
//   - 點預覽上的圖片：框在圖片、面板跳到圖片頁
//   - 浮水印素材：時間軸點它就有框；進浮水印分頁框還在、面板編的是它
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/watermark_layer.dart';
import 'package:markcut/widgets/watermark_panel.dart';

import 'editor_harness.dart';

/// 畫出來的選取框（全域浮水印、素材各一個外層，框都畫在那裡）
Finder get _frames => find.descendant(
  of: find.byType(WmFrameOverlay),
  matching: find.byType(DecoratedBox),
);

Color _frameColor(WidgetTester t) {
  final box = t.widget<DecoratedBox>(_frames);
  return ((box.decoration as BoxDecoration).border! as Border).top.color;
}

/// 預覽上的浮水印圖層（面板裡沒有，第一個就是預覽那個）；它鋪滿畫布
Finder get _layer => find.byType(WatermarkLayer).first;

/// 畫布上的某一點（0~1）
Offset _canvasAt(WidgetTester t, double x, double y) {
  final r = t.getRect(_layer);
  return Offset(r.left + r.width * x, r.top + r.height * y);
}

/// 框的中心落在畫布的哪裡（0~1）
Offset _frameAt(WidgetTester t) {
  final canvas = t.getRect(_layer);
  final c = t.getRect(_frames).center;
  return Offset(
    (c.dx - canvas.left) / canvas.width,
    (c.dy - canvas.top) / canvas.height,
  );
}

Finder get _wmTab => find.widgetWithText(Tab, '浮水印');

/// 面板置頂導覽列的一格（導覽列排在面板最前面）
Finder _nav(String label) => find
    .descendant(of: find.byType(WatermarkPanel), matching: find.text(label))
    .first;

Finder get _textInput => find.byKey(const ValueKey('watermark-text-input'));

/// 文字在上（y 0.3）、圖片在下（y 0.75）：框落在哪個一看就知道
WatermarkSettings _textAndLogo({String text = '買電腦'}) {
  final s = WatermarkSettings(text: TextMark(text: text, y: 0.3));
  s.logo
    ..enabled = true
    ..y = 0.75
    ..sizeFrac = 0.2
    ..bytesValue = solidPng(255, 0, 0);
  return s;
}

Future<void> _pumpEditor(WidgetTester t, WatermarkSettings wm) async {
  await t.pumpWidget(
    editorApp(VideoEditorScreen(blank: true, initialWatermark: wm)),
  );
  await settle(t, 5);
}

Future<void> _openWmTab(WidgetTester t) async {
  await t.tap(_wmTab);
  // 分頁動畫 300ms 跑完監聽器才會動
  await settle(t, 12);
}

Future<void> _dispose(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await settle(t, 3);
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('取消選取後點「浮水印」分頁：預覽出現琥珀框，框在文字上', (t) async {
    await _pumpEditor(t, _textAndLogo());
    // 使用者的現場：點過別的東西（時間軸空白），浮水印就不是選取中了
    editorOf(t).onSelect(-1);
    await settle(t, 3);
    expect(editorOf(t).wmSelected, isFalse);
    expect(_frames, findsNothing);

    await _openWmTab(t);
    expect(_frames, findsOneWidget, reason: '進浮水印分頁就是在編它，預覽上要有框');
    expect(_frameColor(t), kSelect, reason: '框要琥珀色');
    expect(_frameAt(t).dy, closeTo(0.3, 0.03), reason: '框要在文字上');
    await _dispose(t);
  });

  testWidgets('面板切「圖片」框換到圖片，切回「文字」換回來', (t) async {
    await _pumpEditor(t, _textAndLogo());
    await _openWmTab(t);

    await t.tap(_nav('圖片'));
    await settle(t, 4);
    expect(_frames, findsOneWidget);
    expect(_frameAt(t).dy, closeTo(0.75, 0.03), reason: '在調圖片，框要在圖片上');

    await t.tap(_nav('文字'));
    await settle(t, 4);
    expect(_frames, findsOneWidget);
    expect(_frameAt(t).dy, closeTo(0.3, 0.03), reason: '切回文字，框跟著回到文字');
    expect(_frameColor(t), kSelect);
    await _dispose(t);
  });

  testWidgets('浮水印分頁裡點空白取消選取，再打字：框回來', (t) async {
    await _pumpEditor(t, _textAndLogo());
    await _openWmTab(t);
    await t.tap(_nav('文字'));
    await settle(t, 4);
    expect(_frames, findsOneWidget);

    // 左上角是空的：點了＝取消所有選取（原本的行為，照舊）
    await t.tapAt(_canvasAt(t, 0.05, 0.05));
    await settle(t, 4);
    expect(_frames, findsNothing, reason: '點空白要能取消選取');

    await t.enterText(_textInput, '買電腦！');
    await settle(t, 4);
    expect(_frames, findsOneWidget, reason: '在面板改的東西，畫面上要亮框');
    expect(_frameAt(t).dy, closeTo(0.3, 0.03));
    expect(_frameColor(t), kSelect);
    await _dispose(t);
  });

  testWidgets('只有圖片沒有文字：進浮水印分頁也框得到，框在圖片上', (t) async {
    final wm = _textAndLogo(text: '');
    await _pumpEditor(t, wm);
    editorOf(t).onSelect(-1);
    await settle(t, 3);
    expect(_frames, findsNothing);

    await _openWmTab(t);
    expect(_frames, findsOneWidget, reason: '預選的是文字但沒有文字，要改框圖片');
    expect(_frameAt(t).dy, closeTo(0.75, 0.03));
    expect(_frameColor(t), kSelect);
    await _dispose(t);
  });

  testWidgets('點預覽上的浮水印圖片：框在圖片上、面板跳到圖片頁', (t) async {
    await _pumpEditor(t, _textAndLogo());
    editorOf(t).onSelect(-1);
    await settle(t, 3);

    await t.tapAt(_canvasAt(t, 0.5, 0.75));
    await settle(t, 12);
    expect(_frames, findsOneWidget);
    expect(_frameAt(t).dy, closeTo(0.75, 0.03), reason: '點的是圖片，框不能跑去文字');
    expect(_textInput, findsNothing, reason: '面板要停在圖片頁，不是文字頁');
    expect(_frameColor(t), kSelect);
    await _dispose(t);
  });

  /// 時間軸上放一個浮水印素材（＋ → 浮水印 加出來的那種），回傳片段 id。
  /// 全域浮水印先清空：畫面上只有這個素材，框是誰的不會搞混
  Future<int> pumpWmClip(WidgetTester t, WatermarkSettings style) async {
    await _pumpEditor(t, WatermarkSettings(text: TextMark(text: '')));
    late int id;
    VideoEditorScreen.debugTimeline!((tl) {
      tl.sources.add(
        MediaSource(
          path: '',
          name: style.text.text,
          kind: ClipKind.wm,
          duration: 3600,
          wmStyle: style,
        ),
      );
      id = tl.nextId();
      tl.clips.add(
        TimelineClip(
          id: id,
          sourceIndex: tl.sources.length - 1,
          trimStart: 0,
          trimEnd: 10,
          offset: 0,
          track: 0,
        ),
      );
    });
    await settle(t, 3);
    return id;
  }

  testWidgets('浮水印素材：點預覽上它的圖片，框在圖片上、面板跳到圖片頁', (t) async {
    await pumpWmClip(t, _textAndLogo());
    expect(_frames, findsNothing, reason: '還沒選它');

    // 素材圖層在「中央點擊判定層」底下：點擊由判定層決定點到哪個部件
    await t.tapAt(_canvasAt(t, 0.5, 0.75));
    await settle(t, 12);
    expect(_frames, findsOneWidget);
    expect(_frameAt(t).dy, closeTo(0.75, 0.03), reason: '點的是圖片，框不能跑去文字');
    expect(_textInput, findsNothing, reason: '面板要停在圖片頁，不是文字頁');
    expect(_frameColor(t), kSelect);
    await _dispose(t);
  });

  testWidgets('浮水印素材：時間軸點它就有琥珀框；進浮水印分頁框還在、面板編的是它', (t) async {
    final id = await pumpWmClip(
      t,
      WatermarkSettings(text: TextMark(text: '買電腦', y: 0.3)),
    );
    expect(_frames, findsNothing, reason: '還沒選它');

    editorOf(t).onSelect(id);
    await settle(t, 3);
    expect(_frames, findsOneWidget, reason: '選著浮水印素材，預覽上要有框');
    expect(_frameColor(t), kSelect);
    expect(_frameAt(t).dy, closeTo(0.3, 0.03));

    await _openWmTab(t);
    expect(_frames, findsOneWidget, reason: '進浮水印分頁框還在');
    await t.tap(_nav('文字'));
    await settle(t, 4);
    expect(_frames, findsOneWidget);
    expect(
      t.widget<TextField>(_textInput).controller!.text,
      '買電腦',
      reason: '面板編的要是這個素材，不能被搶去編全域浮水印',
    );
    await _dispose(t);
  });
}
