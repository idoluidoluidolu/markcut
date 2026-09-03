// 影片編輯頁的兩條版面守門（都用真的頁面跑，不是拆出來的小元件）：
//
// 1. 底部工具列的前四顆順序＝切割／複製／刪除／貼上。
//    刪除刻意不貼著切割——兩顆都在改結構，按錯就是誤刪。
//    順序寫在 build 裡沒有任何型別擋著，改版時很容易被推回去。
//
// 2. 全螢幕預覽時 AppBar 整個收掉，右上角那顆「離開全螢幕」不能
//    跑到瀏海／狀態列底下（使用者原話：「放大後 整個右上角控制列
//    跑到按不到的區域了」）。同時要證明「非全螢幕的版面一格都沒動」
//    ——AppBar 在的時候 Scaffold 已經把上緣內距從 body 拿掉了，
//    body 裡的 SafeArea 對上緣本來就是 0。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/screens/video_editor_screen.dart';

/// 8×8 PNG（測試自己寫出來，不依賴任何外部檔案）
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
    'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=';
late final String _png;

Map<String, dynamic> _draft() => {
  'savedAt': '2026-08-12T00:00:00.000',
  'sources': [
    MediaSource(
      path: _png,
      name: 't.png',
      kind: ClipKind.image,
      w: 400,
      h: 400,
      duration: 3600,
    ).toJson(),
  ],
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
  'speed': 1.0,
  'ratio': 0,
  'res': 0,
  'quality': 0,
  'wmStart': 0.0,
  'extraTracks': 0,
};

Future<void> _settle(WidgetTester t, [int n = 25]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  late Directory tmpDir;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDownAll(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUpAll(() {
    tmpDir = Directory.systemTemp.createTempSync('markcut_tb_fs_');
    final f = File('${tmpDir.path}${Platform.pathSeparator}t.png')
      ..writeAsBytesSync(base64Decode(_pngB64));
    _png = f.path;

    final b = TestWidgetsFlutterBinding.ensureInitialized();
    // 測試環境沒有這些原生外掛，擋掉不然頁面一開就丟例外
    for (final ch in const [
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
  });

  testWidgets('底部工具列前四顆：切割 → 複製 → 刪除 → 貼上', (t) async {
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    await t.pumpWidget(MaterialApp(home: VideoEditorScreen(draft: _draft())));
    await _settle(t);

    double x(String label) => t.getRect(find.text(label)).center.dx;

    // 由左至右。刪除不能貼著切割（誤觸＝直接刪掉片段）
    expect(x('切割'), lessThan(x('複製')), reason: '切割在複製左邊');
    expect(x('複製'), lessThan(x('刪除')), reason: '複製要排在刪除前面');
    expect(x('刪除'), lessThan(x('貼上')), reason: '刪除在貼上左邊');

    // 搬的是整顆按鈕，不是只換標籤：圖示要跟著自己的標籤走
    // （只調換兩個字串的話，這兩條會抓到對方的圖示）
    Finder entry(String label) =>
        find.ancestor(of: find.text(label), matching: find.byType(Tooltip));
    expect(
      find.descendant(of: entry('複製'), matching: find.byIcon(Icons.copy)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: entry('刪除'),
        matching: find.byIcon(Icons.delete_outline),
      ),
      findsOneWidget,
    );
  });

  testWidgets('全螢幕：右上角離開鈕在安全區內，非全螢幕的位置不變', (t) async {
    // 瀏海：DPR 1 之下實體 94px＝94 邏輯像素
    t.view.physicalSize = const Size(1100, 2200);
    t.view.devicePixelRatio = 1.0;
    t.view.padding = const FakeViewPadding(top: 94);
    addTearDown(t.view.reset);

    await t.pumpWidget(MaterialApp(home: VideoEditorScreen(draft: _draft())));
    await _settle(t);

    const inset = 94.0;
    final appBarBottom = t.getRect(find.byType(AppBar)).bottom;
    expect(appBarBottom, greaterThan(inset), reason: 'AppBar 本來就蓋過瀏海');

    // 非全螢幕：AppBar 在，Scaffold 已經把 body 的上緣內距拿掉，
    // 右上角膠囊只差外距＋內距。多包一層 SafeArea 的話這裡會多 94
    final hintTop = t.getRect(find.byIcon(Icons.fullscreen)).top;
    expect(hintTop, greaterThanOrEqualTo(appBarBottom));
    expect(
      hintTop,
      lessThan(appBarBottom + inset),
      reason: '非全螢幕不能被安全區再推一次（版面必須跟以前一樣）',
    );

    // 全螢幕：AppBar 收掉，預覽頂到螢幕最上緣——離開鈕要在瀏海底下
    await t.tap(find.byIcon(Icons.fullscreen));
    await _settle(t, 6);
    expect(find.byType(AppBar), findsNothing, reason: '全螢幕沒有 AppBar');
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    expect(
      t.getRect(find.byIcon(Icons.fullscreen_exit)).top,
      greaterThanOrEqualTo(inset),
      reason: '全螢幕的離開鈕不能壓在狀態列／瀏海上',
    );
  });
}
