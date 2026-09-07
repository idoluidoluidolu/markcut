// 迴歸守門（稽核 #11）：圖片／貼圖調整視窗與文字視窗的復原粒度。
//
// 圖片／貼圖的 change() 以前每一次 onChanged 都 _pushUndo：拉一趟滑桿
// ＝幾十步復原，六十份上限一下就被灌爆；文字視窗的 both() 則一份都不
// 拍，改完字型顏色按上一步退的是更早的別的動作。現在三個視窗都跟馬賽克
// 表一樣：第一筆改動拍一份，整個視窗算一步。
//
// 圖片用測試自己寫出來的 8×8 PNG 走真的編輯頁（草稿載入會把圖讀進
// 縮圖／圖層）；文字片段不需要檔案
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';

import 'editor_harness.dart';

late final String _png;

Map<String, dynamic> _draft(MediaSource src) => {
  'savedAt': '2026-09-01T00:00:00.000',
  'sources': [src.toJson()],
  'clips': [
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 4,
      offset: 0,
      track: 0,
    ).toJson(),
  ],
  'ratio': 0,
  'res': 0,
  'quality': 0,
  'wmStart': 0.0,
  'extraTracks': 0,
};

void main() {
  late Directory tmpDir;

  setUpAll(() {
    tmpDir = Directory.systemTemp.createTempSync('markcut_sheet_undo_');
    final f = File('${tmpDir.path}${Platform.pathSeparator}t.png')
      ..writeAsBytesSync(solidPng(200, 40, 40));
    _png = f.path;
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    bigPhoneView(b);
    mockEditorPlugins(b);
  });

  tearDownAll(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 選取 1 號片段，再點一下開它的調整視窗
  Future<void> openSheet(WidgetTester t) async {
    await t.tapAt(t.getCenter(clipBlock(1)));
    await settle(t, 6);
    await t.tapAt(t.getCenter(clipBlock(1)));
    await settle(t, 10);
  }

  /// 點視窗外面把它收掉
  Future<void> closeSheet(WidgetTester t) async {
    await t.tapAt(const Offset(20, 20));
    await settle(t, 10);
  }

  testWidgets('圖片視窗：拉兩趟「大小」滑桿，上一步一次退回開視窗前，而且只有這一步', (t) async {
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(
          draft: _draft(
            MediaSource(
              path: _png,
              name: 't.png',
              kind: ClipKind.image,
              w: 8,
              h: 8,
              duration: 3600,
            ),
          ),
        ),
      ),
    );
    await settle(t);
    expect(undoEnabled(t), isFalse, reason: '載入草稿不算一步');
    expect(clipOf(t, 1).scale, closeTo(1.0, 1e-9));

    await openSheet(t);
    expect(find.text('透明度'), findsOneWidget, reason: '圖片的調整視窗要開著');
    final slider = sliderLabelled('大小');
    // 兩趟、每趟至少兩個 onChanged：以前這樣就是四份以上的快照
    await t.drag(slider, const Offset(60, 0));
    await settle(t, 3);
    await t.drag(slider, const Offset(60, 0));
    await settle(t, 3);
    expect(clipOf(t, 1).scale, isNot(closeTo(1.0, 1e-6)), reason: '滑桿真的動了');
    await closeSheet(t);
    expect(find.text('透明度'), findsNothing);

    expect(undoEnabled(t), isTrue);
    await t.tap(undoButton());
    await settle(t, 6);
    expect(clipOf(t, 1).scale, closeTo(1.0, 1e-6), reason: '一步退回開視窗前');
    expect(undoEnabled(t), isFalse, reason: '整個視窗只算一步，不是每格滑桿一步');
    await settle(t, 80);
  });

  testWidgets('文字視窗：改內容之後按上一步，退得回去', (t) async {
    await t.pumpWidget(
      editorApp(
        VideoEditorScreen(
          draft: _draft(
            MediaSource(path: '', name: 'hi', kind: ClipKind.text, duration: 3600),
          ),
        ),
      ),
    );
    await settle(t);
    expect(undoEnabled(t), isFalse);

    await openSheet(t);
    final field = find.byType(TextField).last;
    expect(field, findsOneWidget, reason: '文字視窗的內容欄要開著');
    await t.enterText(field, 'hello');
    await settle(t, 3);
    expect(modelOf(t).sources[0].name, 'hello');
    await closeSheet(t);

    expect(undoEnabled(t), isTrue, reason: '文字視窗的改動也要進復原');
    await t.tap(undoButton());
    await settle(t, 6);
    expect(modelOf(t).sources[0].name, 'hi', reason: '上一步退回改字前');
    expect(undoEnabled(t), isFalse, reason: '整個視窗只算一步');
    await settle(t, 80);
  });
}
