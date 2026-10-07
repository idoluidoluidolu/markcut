// 個人中心 GIF 分頁的排序（乙案：分頁列右邊的膠囊寫著現在怎麼排，
// 點開選「最新在前／最舊在前／隨機排序」）：
//   1. 預設新到舊，膠囊寫「最新在前」
//   2. 選「最舊在前」整排倒過來，選過的記住，下次進來照舊
//   3. 「隨機排序」還是同一批 GIF，一個不少
//   4. 別的分頁、不到兩個 GIF、批次刪除時沒有膠囊
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/services/gif_store.dart';
import 'package:markcut/theme.dart';

/// 最小的合法 GIF（1×1 透明）：每一格都是正方形，瀑布流照順序左右交錯排
const _gif = <int>[
  71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, //
  255, 255, 255, 33, 249, 4, 1, 10, 0, 1, 0, 44, 0, 0, 0, 0, //
  1, 0, 1, 0, 0, 2, 2, 76, 1, 0, 59,
];

late Directory _docs;
late Directory _gifDir;

/// 放 [names] 這幾個 GIF，越後面越新（修改時間一天一天往後）
List<String> _putGifs(List<String> names) {
  for (final f in _gifDir.listSync()) {
    f.deleteSync();
  }
  return [
    for (final (i, n) in names.indexed)
      (File('${_gifDir.path}${Platform.pathSeparator}$n.gif')
            ..writeAsBytesSync(_gif)
            ..setLastModifiedSync(DateTime(2026, 1, 1 + i)))
          .path,
  ];
}

/// SharedPreferences、讀檔、解 GIF 都是真的非同步，要 runAsync 才推得動
Future<void> _settle(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// 真的 iPhone 14（邏輯 390×844）：五個 GIF 三排，一個畫面放得下
Future<void> _openGifTab(WidgetTester t) async {
  t.view.devicePixelRatio = 3;
  t.view.physicalSize = const Size(390 * 3, 844 * 3);
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      debugShowCheckedModeBanner: false,
      home: const ProfileScreen(),
    ),
  );
  await _settle(t);
  await t.tap(find.byKey(const ValueKey('profile-tab-1')));
  await _settle(t);
}

/// 畫面上的順序：每一格都是正方形，由上而下、由左而右讀
List<String> _shown(WidgetTester t, List<String> refs) {
  final at = {
    for (final r in refs)
      r: t.getTopLeft(find.byKey(ValueKey('profile-gif-$r'))),
  };
  return [...refs]..sort((a, b) {
    final dy = at[a]!.dy.compareTo(at[b]!.dy);
    return dy != 0 ? dy : at[a]!.dx.compareTo(at[b]!.dx);
  });
}

Finder get _chip => find.byKey(const ValueKey('profile-gif-sort'));

String _chipText(WidgetTester t) => t
    .widget<Text>(find.descendant(of: _chip, matching: find.byType(Text)))
    .data!;

Future<void> _pick(WidgetTester t, String label) async {
  await t.tap(_chip);
  await _settle(t, 10);
  await t.tap(find.text(label).last);
  await _settle(t, 10);
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    _docs = Directory.systemTemp.createTempSync('markcut_gif_sort');
    _gifDir = Directory('${_docs.path}${Platform.pathSeparator}gifs')
      ..createSync(recursive: true);
    GifStore.documentsDirOverride = _docs;
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _docs.path,
    );
  });

  tearDownAll(() {
    GifStore.documentsDirOverride = null;
    try {
      _docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('預設最新在前；選最舊在前整排倒過來，下次進來照舊', (t) async {
    final [a, b, c] = _putGifs(['a', 'b', 'c']);
    await _openGifTab(t);
    expect(_chipText(t), '最新在前');
    expect(_shown(t, [a, b, c]), [c, b, a]);

    await _pick(t, '最舊在前');
    expect(_chipText(t), '最舊在前');
    expect(_shown(t, [a, b, c]), [a, b, c]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile.gifSort'), 'oldest');

    // 離開再進來：記得上次選的
    await t.pumpWidget(const SizedBox());
    await _settle(t, 5);
    await _openGifTab(t);
    expect(_chipText(t), '最舊在前');
    expect(_shown(t, [a, b, c]), [a, b, c]);

    await t.pumpWidget(const SizedBox());
    await _settle(t, 5);
  });

  testWidgets('隨機排序：還是同一批 GIF，一個不少', (t) async {
    final refs = _putGifs(['a', 'b', 'c', 'd', 'e']);
    await _openGifTab(t);
    await _pick(t, '隨機排序');
    expect(_chipText(t), '隨機排序');
    final shown = _shown(t, refs);
    expect(shown.toSet(), refs.toSet());
    expect(shown.length, refs.length);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('profile.gifSort'), 'random');

    await t.pumpWidget(const SizedBox());
    await _settle(t, 5);
  });

  testWidgets('別的分頁、不到兩個 GIF、批次刪除時沒有排序膠囊', (t) async {
    _putGifs(['a', 'b']);
    await _openGifTab(t);
    expect(_chip, findsOneWidget);

    // 批次刪除：收起來
    await t.tap(find.byKey(const ValueKey('profile-batch')));
    await _settle(t, 5);
    expect(_chip, findsNothing);
    await t.tap(find.text('取消'));
    await _settle(t, 5);
    expect(_chip, findsOneWidget);

    // 草稿、範本分頁：沒有
    for (final tab in [0, 2]) {
      await t.tap(find.byKey(ValueKey('profile-tab-$tab')));
      await _settle(t, 5);
      expect(_chip, findsNothing);
    }

    // 只有一個 GIF：沒有東西好排
    await t.pumpWidget(const SizedBox());
    await _settle(t, 5);
    _putGifs(['a']);
    await _openGifTab(t);
    expect(_chip, findsNothing);

    await t.pumpWidget(const SizedBox());
    await _settle(t, 5);
  });
}
