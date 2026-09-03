// 編輯頁不收「右滑＝上一頁」（使用者指定：影片編輯模式、圖片編輯
// 模式、GIF 製作等等，都不要加入右滑上一頁）。
//
// 兩層保護：
//   1. 機制本身——真的在 iOS 上從左緣甩一把，看人有沒有被送回上一頁。
//      （偵測器本身還是會被塞進轉場裡，只是 enabledCallback 回 false
//      讓它接不到手勢，所以不能靠「找不找得到那個 widget」來驗）
//   2. 覆蓋率——掃 lib/ 的原始碼，任何一個編輯頁只要被 MaterialPageRoute
//      推出去就當掉；而且 lib/screens/ 底下每一支都得先在下面歸類，
//      新增一頁忘了歸類會直接失敗，不會默默漏掉
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/nav.dart';

/// 編輯模式的頁：進去就開始改東西，滿場橫向手勢。
/// 檔名 → 這一支裡面會被 push 的頁面 class
const _editors = <String, List<String>>{
  'video_editor_screen.dart': ['VideoEditorScreen'],
  'photo_editor_screen.dart': ['PhotoEditorScreen'],
  'batch_watermark_screen.dart': ['BatchWatermarkScreen'],
  'gif_screen.dart': ['GifScreen'],
  'watermark_studio_screen.dart': ['WatermarkStudioScreen'],
  'collage_screen.dart': ['CollageScreen'],
  'crop_screen.dart': ['CropScreen'],
  'draw_screen.dart': ['_DrawScreen'],
};

/// 瀏覽用的頁：右滑返回照舊，使用者只嫌編輯頁誤觸
const _browsers = <String>{
  'home_screen.dart',
  'profile_screen.dart',
  'presets_screen.dart',
  'about_screen.dart',
  'donate_screen.dart',
  'feedback_screen.dart',
  'probe_screen.dart',
  'playback_test_screen.dart',
};

/// `MaterialPageRoute(builder: (_) => Foo(` / `editRoute(... builder: (_) => Foo(`
final _push = RegExp(
  r'(MaterialPageRoute|editRoute)\s*(?:<[^>]*>)?\s*\(\s*'
  r'(?:fullscreenDialog:\s*\w+,\s*)?'
  r'builder:\s*\([^)]*\)\s*=>\s*(?:const\s+)?([A-Za-z_]\w*)',
);

/// 在 iOS 上把 [route] 推出去，然後從螢幕左緣往右甩一把，
/// 回報「被推出去的那一頁還在不在」
Future<bool> _survivesEdgeSwipe(WidgetTester tester, Route<void> route) async {
  // 轉場的手勢是看 Theme.platform 決定的；復原一定要在測試主體裡做，
  // 框架在 tearDown 之前就會檢查 debug 變數有沒有被留著
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.push(ctx, route),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('第二頁'), findsOneWidget, reason: '推不出去就沒得測');

    // 從左緣（_kBackGestureWidth 是 20pt）往右拉超過半個螢幕：
    // 手勢有效的話放手就會 pop
    final g = await tester.startGesture(const Offset(2, 300));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(100, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    return find.text('第二頁').evaluate().isNotEmpty;
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Widget _page2() => const Scaffold(body: Center(child: Text('第二頁')));

void main() {
  group('機制', () {
    test('editRoute 關掉 pop 手勢，一般的 MaterialPageRoute 沒關', () {
      final r = editRoute<void>(builder: (_) => const SizedBox());
      expect(r, isA<EditPageRoute<void>>());
      expect((r as EditPageRoute<void>).popGestureEnabled, isFalse);
    });

    testWidgets('iOS 對照組：一般的頁面左緣右滑會退回上一頁', (tester) async {
      final alive = await _survivesEdgeSwipe(
        tester,
        MaterialPageRoute<void>(builder: (_) => _page2()),
      );
      expect(alive, isFalse, reason: '一般頁面本來就該滑得回去');
    });

    testWidgets('iOS：編輯頁左緣右滑滑不掉，人還在那一頁', (tester) async {
      final alive = await _survivesEdgeSwipe(
        tester,
        editRoute<void>(builder: (_) => _page2()),
      );
      expect(alive, isTrue, reason: '編輯頁不收右滑返回');
    });
  });

  group('覆蓋率（掃原始碼）', () {
    final screens = Directory('lib/screens')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.dart'))
        .toSet();

    test('lib/screens 底下每一支都歸過類（新增畫面要來這裡加一行）', () {
      final known = {..._editors.keys, ..._browsers};
      expect(
        screens.difference(known),
        isEmpty,
        reason:
            '新的畫面要先決定它是編輯頁還是瀏覽頁：編輯頁加進 _editors '
            '並且用 editRoute 推，瀏覽頁加進 _browsers',
      );
      expect(known.difference(screens), isEmpty, reason: '清單裡有不存在的檔案');
    });

    test('編輯頁一律用 editRoute 推，沒有一個漏網', () {
      final wanted = {for (final v in _editors.values) ...v};
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final m in _push.allMatches(src)) {
          if (m.group(1) == 'MaterialPageRoute' &&
              wanted.contains(m.group(2))) {
            bad.add('${f.path}: ${m.group(2)}');
          }
        }
      }
      expect(bad, isEmpty, reason: '這些編輯頁還在用 MaterialPageRoute 推：$bad');
    });

    test('每個編輯頁至少真的有一個 editRoute 的推送點', () {
      final seen = <String>{};
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        for (final m in _push.allMatches(f.readAsStringSync())) {
          if (m.group(1) == 'editRoute') seen.add(m.group(2)!);
        }
      }
      for (final v in _editors.values) {
        for (final cls in v) {
          expect(seen, contains(cls), reason: '$cls 沒有任何 editRoute 推送點');
        }
      }
    });
  });
}
