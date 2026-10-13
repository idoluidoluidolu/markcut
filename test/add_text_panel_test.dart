// 加素材 → 文字：直接開文字樣式面板（10-13 使用者指定），不再先跳一個
// 只能打字的對話框。這支盯四件事：
//   1. 一按就是樣式面板：輸入框自己拿到焦點（跳鍵盤），橫式／直式、對齊、
//      字型、顏色、大小都在；時間軸上已經有一段空白文字
//   2. 打字＝片段文字跟著變；按完成留下，上一步一次退到沒加這段文字
//   3. 一個字都沒打就收掉＝沒加：片段收回，上一步沒有多一步空的
//   4. 打了又刪光再收掉：一樣收回，上一步也不留那一步
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';

import 'editor_harness.dart';

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    mockEditorPlugins(b);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Finder field() => find.byKey(const ValueKey('clip-text-content'));

  List<TimelineClip> textClips(WidgetTester t) {
    final m = modelOf(t);
    return [
      for (final c in m.clips)
        if (m.sourceOf(c).kind == ClipKind.text) c,
    ];
  }

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 15);
  }

  Future<void> addText(WidgetTester t) async {
    await t.tap(find.text('加素材'));
    await tick(t, 15);
    await t.tap(find.text('文字'));
    await tick(t, 15);
  }

  Future<void> close(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('clip-text-done')));
    await tick(t, 20);
  }

  testWidgets('一按就是樣式面板：輸入框自己拿到焦點，樣式都在', (t) async {
    await open(t);
    expect(undoEnabled(t), isFalse);
    await addText(t);

    expect(find.text('輸入文字'), findsNothing, reason: '還是舊的只能打字的對話框');
    expect(field(), findsOneWidget, reason: '加文字沒有直接開樣式面板');
    final tf = t.widget<TextField>(field());
    expect(tf.focusNode?.hasFocus ?? tf.autofocus, isTrue, reason: '要直接跳鍵盤打字');
    for (final k in const [
      'clip-text-direction',
      'clip-text-alignment',
      'text-insert-time',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.text('顏色'), findsWidgets);
    expect(textClips(t), hasLength(1), reason: '時間軸上要先有一段文字');

    await t.enterText(field(), '週末小旅行');
    await t.pump();
    final src = modelOf(t).sourceOf(textClips(t).single);
    expect(src.name, '週末小旅行');
    expect(src.textStyle!.text, '週末小旅行');

    await close(t);
    expect(textClips(t), hasLength(1), reason: '打了字的要留下');
    expect(undoEnabled(t), isTrue);
    await t.tap(undoButton());
    await tick(t, 20);
    expect(textClips(t), isEmpty, reason: '上一步要一次退到沒加這段文字');
    expect(t.takeException(), isNull);
    await tick(t, 100);
  });

  testWidgets('一個字都沒打就收掉＝沒加，上一步沒有多一步', (t) async {
    await open(t);
    await addText(t);
    expect(textClips(t), hasLength(1));
    await close(t);
    expect(textClips(t), isEmpty, reason: '空白文字片段留在時間軸上');
    expect(modelOf(t).sources, isEmpty, reason: '來源沒收回');
    expect(undoEnabled(t), isFalse, reason: '上一步多了一步空的');
    expect(t.takeException(), isNull);
    await tick(t, 100);
  });

  testWidgets('打了又刪光再收掉：一樣收回，上一步不留那一步', (t) async {
    await open(t);
    await addText(t);
    await t.enterText(field(), '打錯');
    await t.pump();
    await t.enterText(field(), '');
    await t.pump();
    await close(t);
    expect(textClips(t), isEmpty);
    expect(undoEnabled(t), isFalse, reason: '退回去是同一個樣子的那一步要拿掉');
    expect(t.takeException(), isNull);
    await tick(t, 100);
  });
}
