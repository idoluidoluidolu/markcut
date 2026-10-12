// 文字輸入框底下那排「時間｜顏文字」（10-12 使用者在提案畫布挑的乙案）。
// 這支盯四件事：
//   1. 寫法：2026/10/12 15:20；接成新的一行（空的就是整段、已換行不多空一行）
//   2. 浮水印面板文字卡：時間、顏文字都在輸入框裡，字型那排沒有顏文字了；
//      按「時間」加一行、輸入框跟設定一起變、先拍復原快照、外框亮一下琥珀
//   3. 空的文字按「時間」：整段就是時間，前面不多一行
//   4. 文字素材的編輯視窗：同一排；按了改到片段文字，上一步一次退回
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/text_insert_bar.dart';
import 'package:markcut/widgets/watermark_panel.dart';

import 'editor_harness.dart';

const _stamp = '2026/10/12 15:20';

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 30));
  }
}

Finder get _time => find.byKey(const ValueKey('text-insert-time'));
Finder get _kaomoji => find.byKey(const ValueKey('text-insert-kaomoji'));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 秒數故意不是 0：寫法只到分鐘
    insertTimeNow = () => DateTime(2026, 10, 12, 15, 20, 45);
  });
  tearDown(() => insertTimeNow = DateTime.now);

  test('寫法：年/月/日 時:分，不足兩位補 0；接成新的一行', () {
    expect(timeStamp(DateTime(2026, 1, 2, 3, 4)), '2026/01/02 03:04');
    expect(timeStampNow(), _stamp);
    expect(appendLine('', 'X'), 'X');
    expect(appendLine('A', 'X'), 'A\nX');
    expect(appendLine('A\n', 'X'), 'A\nX');
  });

  Future<WatermarkSettings> pumpPanel(
    WidgetTester t,
    String text, {
    VoidCallback? onBeforeChange,
    VoidCallback? onChanged,
  }) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final settings = WatermarkSettings();
    settings.text.text = text;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WatermarkPanel(
            settings: settings,
            onBeforeChange: onBeforeChange,
            onChanged: onChanged ?? () {},
          ),
        ),
      ),
    );
    await _settle(t);
    await t.tap(find.text('文字').first);
    await _settle(t);
    return settings;
  }

  testWidgets('浮水印文字卡：按「時間」加一行現在的時間，先拍復原、外框亮一下', (t) async {
    WatermarkSettings? undo;
    var changes = 0;
    late WatermarkSettings settings;
    settings = await pumpPanel(
      t,
      '@我的浮水印',
      onBeforeChange: () => undo = settings.copy(),
      onChanged: () => changes++,
    );

    final box = find.byKey(const ValueKey('watermark-text-box'));
    final input = find.byKey(const ValueKey('watermark-text-input'));
    // 時間、顏文字都在輸入框裡（底部那排）；整張卡只有這一顆顏文字
    expect(find.descendant(of: box, matching: _time), findsOneWidget);
    expect(find.descendant(of: box, matching: _kaomoji), findsOneWidget);
    expect(find.text('顏文字'), findsOneWidget, reason: '字型那排還留著舊的顏文字');

    await t.ensureVisible(_time);
    await t.tap(_time);
    await t.pump();
    expect(settings.text.text, '@我的浮水印\n$_stamp');
    final ctrl = t.widget<TextField>(input).controller!;
    expect(ctrl.text, settings.text.text, reason: '輸入框沒跟著變');
    expect(ctrl.selection.baseOffset, settings.text.text.length);
    expect(undo!.text.text, '@我的浮水印', reason: '復原快照要在改之前拍');
    expect(changes, 1, reason: '父層沒收到改動（預覽、草稿不會跟著變）');

    Color border() =>
        ((t.widget<AnimatedContainer>(box).decoration! as BoxDecoration).border!
                as Border)
            .top
            .color;
    expect(border(), kSelect, reason: '按了外框要亮一下');
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 500));
    expect(border(), kClipBorder, reason: '亮完要淡回原本的框');

    // 再按一次：再多一行，不吃掉前一行
    await t.tap(_time);
    await t.pump(const Duration(milliseconds: 700));
    expect(settings.text.text, '@我的浮水印\n$_stamp\n$_stamp');
    expect(t.takeException(), isNull);
  });

  testWidgets('空的文字按「時間」：整段就是時間，前面不多一行', (t) async {
    final settings = await pumpPanel(t, '');
    await t.ensureVisible(_time);
    await t.tap(_time);
    await t.pump(const Duration(milliseconds: 700));
    expect(settings.text.text, _stamp);
    expect(t.takeException(), isNull);
  });

  testWidgets('文字素材的編輯視窗：同一排，按「時間」改到片段文字，上一步一次退回', (t) async {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    mockEditorPlugins(b);
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late TimelineModel tl;
    await t.pumpWidget(editorApp(const VideoEditorScreen(blank: true)));
    await tick(t, 5);
    VideoEditorScreen.debugTimeline!((m) {
      tl = m;
      m.sources.add(
        MediaSource(
          path: '',
          name: '你好',
          kind: ClipKind.text,
          duration: 3600,
          textStyle: TextMark(text: '你好'),
        ),
      );
      m.clips.add(
        TimelineClip(
          id: m.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 4,
          offset: 0,
          track: 0,
        ),
      );
    });
    await tick(t, 15);
    editorOf(t).onTapSelectedClip!(tl.clips.single.id);
    await tick(t, 15);

    final field = find.byKey(const ValueKey('clip-text-content'));
    expect(field, findsOneWidget);
    expect(_time, findsOneWidget);
    expect(_kaomoji, findsOneWidget);
    expect(find.text('顏文字'), findsOneWidget, reason: '舊的顏文字鈕還在');

    await t.tap(_time);
    await t.pump();
    final src = tl.sources.single;
    expect(src.name, '你好\n$_stamp');
    expect(src.textStyle!.text, '你好\n$_stamp');
    expect(t.widget<TextField>(field).controller!.text, '你好\n$_stamp');

    await t.tap(find.byKey(const ValueKey('clip-text-done')));
    await tick(t, 20);
    expect(undoEnabled(t), isTrue);
    await t.tap(undoButton());
    await tick(t, 20);
    expect(modelOf(t).sources.single.name, '你好', reason: '上一步要一次退回加時間之前');
    expect(t.takeException(), isNull);
    await tick(t, 100);
  });
}
