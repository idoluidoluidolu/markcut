// 我的 GIF 的燈箱（點一下放大看那一層）的守門測試。
//
// 三件事很容易在改版時掉：左右滑換上一張／下一張、往下滑關掉、
// 長按刪掉的是「眼前這一張」而不是點進來的那一張。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_image.dart';

/// 最小的合法 GIF（1×1 透明）——燈箱不看畫面內容，有真的檔案就夠
const _gif = <int>[
  71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, //
  255, 255, 255, 33, 249, 4, 1, 10, 0, 1, 0, 44, 0, 0, 0, 0, //
  1, 0, 1, 0, 0, 2, 2, 76, 1, 0, 59,
];

late Directory _gifDir;

/// 圖片解碼、檔案讀寫都在真的 IO 上，pump 一輪不夠
Future<void> _settle(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 往下甩一段再放手。timeStamp 一定要給，不然每一筆事件都是 t=0，
/// 速度量到 0，甩的手勢會被當成慢慢拖
Future<void> _flingDown(WidgetTester t, double dy) async {
  final g = await t.startGesture(const Offset(195, 300));
  var ts = const Duration(milliseconds: 20);
  for (var k = 0; k < 4; k++) {
    await g.moveBy(Offset(0, dy / 4), timeStamp: ts);
    await t.pump(const Duration(milliseconds: 20));
    ts += const Duration(milliseconds: 20);
  }
  await g.up();
  await _settle(t, 8);
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('markcut_lightbox');
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    _gifDir = Directory('${dir.path}${Platform.pathSeparator}gifs')
      ..createSync(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final f in _gifDir.listSync().whereType<File>()) {
      f.deleteSync();
    }
    // 排序是照修改時間新到舊，寫入順序就是清單順序的反面
    for (final n in ['c', 'b', 'a']) {
      File('${_gifDir.path}${Platform.pathSeparator}$n.gif')
        ..writeAsBytesSync(_gif)
        ..setLastModifiedSync(
          DateTime(2026, 1, 1).add(Duration(days: 'abc'.indexOf(n))),
        );
    }
  });

  Future<void> pumpGrid(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 780));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: const LightPage(child: GifsScreen()),
      ),
    );
    await _settle(tester);
    expect(find.byType(GifImage), findsNWidgets(3));
  }

  testWidgets('左右滑換上一張／下一張，滑到頭不會繞回去', (tester) async {
    await pumpGrid(tester);
    await tester.tap(find.byType(GifImage).first);
    await _settle(tester, 8);
    final pv = find.byType(PageView);
    expect(pv, findsOneWidget, reason: '點一下沒有打開燈箱');
    final ctrl = tester.widget<PageView>(pv).controller!;
    expect(ctrl.page!.round(), 0);

    await tester.drag(pv, const Offset(-300, 0));
    await _settle(tester, 8);
    expect(ctrl.page!.round(), 1, reason: '往左滑沒有換到下一張');

    await tester.drag(pv, const Offset(300, 0));
    await _settle(tester, 8);
    expect(ctrl.page!.round(), 0, reason: '往右滑沒有回到上一張');

    // 第一張再往右滑：停在原地，不繞到最後一張
    await tester.drag(pv, const Offset(300, 0));
    await _settle(tester, 8);
    expect(ctrl.page!.round(), 0, reason: '滑到頭繞回去了');
    expect(tester.takeException(), isNull);
  });

  testWidgets('往下滑關掉；只滑一點點會彈回去', (tester) async {
    await pumpGrid(tester);
    await tester.tap(find.byType(GifImage).first);
    await _settle(tester, 8);
    expect(find.byType(PageView), findsOneWidget);

    // 一點點：留在原地
    await _flingDown(tester, 24);
    expect(find.byType(PageView), findsOneWidget, reason: '滑一點點就被關掉了');

    // 滑過門檻：關掉
    await _flingDown(tester, 240);
    expect(find.byType(PageView), findsNothing, reason: '往下滑沒有關掉燈箱');
    expect(tester.takeException(), isNull);
  });

  testWidgets('翻頁之後長按，刪掉的是眼前那一張', (tester) async {
    await pumpGrid(tester);
    await tester.tap(find.byType(GifImage).first);
    await _settle(tester, 8);

    // 翻到第二張
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await _settle(tester, 8);
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page!.round(),
      1,
    );

    await tester.longPress(find.byType(PageView));
    await _settle(tester, 8);
    expect(find.text('刪除這個 GIF？'), findsOneWidget, reason: '長按沒有問要不要刪');
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await _settle(tester, 12);

    // 清單是新到舊（a、b、c），第二張＝b
    final left = _gifDir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(left, ['a.gif', 'c.gif'], reason: '刪掉的不是眼前那一張');
    expect(find.byType(PageView), findsNothing, reason: '刪完沒有把燈箱關掉');
    expect(tester.takeException(), isNull);
  });
}
