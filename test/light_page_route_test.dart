// 淺色頁一定要包著 LightPage 推出去（見 theme.dart 的 LightPage）。
//
// 路由是掛在 Navigator 底下建的，拿到的是 App 層的深色佈景，不是推它
// 的那一頁的：漏包的話頁面自己寫死的白底看起來是白的，但 Theme.of 是
// 深色——AppBar 的返回鍵是深色頁的灰（#B9B9C2，白底上對比約 1.9:1）、
// 水波與對話框全走深色值；從那頁 showLicensePage 開出來的套件授權清單
// 更是整頁黑（SDK 用 InheritedTheme.capture 抓當下的佈景）。
// 「開源授權」「隱私」兩頁就漏過。
//
// 兩層保護（跟 edit_route_test 同一套）：
//   1. 機制——真的從關於頁點進「開源授權」「隱私」，看佈景亮不亮、
//      返回鍵是不是淺色頁的顏色、套件授權清單是不是淺色。
//      順便守授權清單上的版本號：要是 main.dart 填進來的 appVersionTag
//      （真的 build 版本），不是寫死的 1.0.0
//   2. 覆蓋率——掃 lib/ 的原始碼：淺色頁只要被 MaterialPageRoute 直接推
//      （沒有 LightPage(child: …) 包著）就當掉；深色頁反過來不准包。
//      lib/screens/ 底下每一個 *Screen／*Page 都得先歸類，新增一頁忘了
//      歸類會直接失敗，不會默默漏掉
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/screens/about_screen.dart';
import 'package:markcut/services/playback_trace.dart';
import 'package:markcut/theme.dart';

/// 淺色頁：編輯畫面以外的瀏覽頁，推出去一律包 LightPage
/// （首頁是 MaterialApp 的 home，main.dart 也是包著推的）
const _light = <String>{
  'HomeScreen',
  'ProfileScreen',
  'DraftsScreen',
  'GifsScreen',
  'PresetsScreen',
  'AboutScreen',
  'DonateScreen',
  '_InfoPage',
};

/// 深色頁（除錯工具）：走 App 預設的深色佈景，不包
const _dark = <String>{'ProbeScreen'};

/// 編輯頁：深色、走 editRoute（歸類與守門在 edit_route_test）
const _editors = <String>{
  'VideoEditorScreen',
  'PhotoEditorScreen',
  'BatchWatermarkScreen',
  'GifScreen',
  'WatermarkStudioScreen',
  'CollageScreen',
  'CropScreen',
  '_DrawScreen',
};

/// `MaterialPageRoute(builder: (_) => Foo(`
final _push = RegExp(
  r'MaterialPageRoute\s*(?:<[^>]*>)?\s*\(\s*'
  r'(?:fullscreenDialog:\s*\w+,\s*)?'
  r'builder:\s*\([^)]*\)\s*=>\s*(?:const\s+)?([A-Za-z_]\w*)',
);

/// `LightPage(child: Foo(`（key 可有可無）
final _wrap = RegExp(
  r'LightPage\s*\(\s*(?:key:[^,]*,\s*)?child:\s*(?:const\s+)?([A-Za-z_]\w*)',
);

/// `class FooScreen extends …`／`class _FooPage extends …`
final _pageClass = RegExp(r'class\s+((?:_?[A-Z]\w*)(?:Screen|Page))\s+extends');

Future<void> _pumpAbout(WidgetTester t) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      home: const LightPage(child: AboutScreen()),
    ),
  );
  await t.pumpAndSettle();
}

ThemeData _themeAt(WidgetTester t, Finder f) => Theme.of(t.element(f));

void main() {
  group('機制', () {
    testWidgets('開源授權：內容頁是淺色佈景，返回鍵是淺色頁的顏色', (t) async {
      await _pumpAbout(t);
      await t.tap(find.text('開源授權'));
      await t.pumpAndSettle();

      final theme = _themeAt(t, find.text('本程式'));
      expect(theme.brightness, Brightness.light, reason: '內容頁掉進深色佈景了');
      expect(
        theme.appBarTheme.iconTheme?.color,
        kLIcon,
        reason: '返回鍵會畫成深色頁的灰（白底上對比只有 1.9:1）',
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('隱私：內容頁是淺色佈景', (t) async {
      await _pumpAbout(t);
      await t.tap(find.text('隱私'));
      await t.pumpAndSettle();
      expect(
        _themeAt(t, find.text('媒體全部在你的裝置上')).brightness,
        Brightness.light,
        reason: '內容頁掉進深色佈景了',
      );
      expect(t.takeException(), isNull);
    });

    testWidgets('第三方套件授權清單：跟著淺色佈景，版本號是真的版本標', (t) async {
      appVersionTag = '9.9.9+42';
      addTearDown(() => appVersionTag = '?');
      await _pumpAbout(t);
      await t.tap(find.text('開源授權'));
      await t.pumpAndSettle();
      // 那顆鈕在三段授權說明的下面，預設的畫布放不下：捲到它露出來
      await t.scrollUntilVisible(
        find.text('第三方套件授權清單'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await t.tap(find.text('第三方套件授權清單'));
      // 清單是串流讀進來的，轉圈圈時 pumpAndSettle 等不到底；固定 pump
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }

      expect(find.byType(LicensePage), findsOneWidget, reason: '清單沒開');
      expect(
        _themeAt(t, find.byType(LicensePage)).brightness,
        Brightness.light,
        reason: '套件授權清單整頁變深色',
      );
      expect(
        find.text('9.9.9+42'),
        findsOneWidget,
        reason: '版本號沒有用 appVersionTag',
      );
      expect(find.text('1.0.0'), findsNothing, reason: '寫死的 1.0.0 還在');
      expect(t.takeException(), isNull);
    });
  });

  group('覆蓋率（掃原始碼）', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    test('lib/screens 底下每一個頁面 class 都歸過類（新增畫面要來這裡加一行）', () {
      final known = {..._light, ..._dark, ..._editors};
      final found = <String>{};
      for (final f in files) {
        if (!f.path.replaceAll('\\', '/').contains('lib/screens/')) continue;
        for (final m in _pageClass.allMatches(f.readAsStringSync())) {
          found.add(m.group(1)!);
        }
      }
      expect(
        found.difference(known),
        isEmpty,
        reason: '新的頁面要先決定它是淺色頁（推的時候包 LightPage）、深色除錯頁還是編輯頁',
      );
      expect(known.difference(found), isEmpty, reason: '清單裡有不存在的頁面');
    });

    test('淺色頁一律包 LightPage 推；深色頁不包', () {
      final bad = <String>[];
      for (final f in files) {
        final src = f.readAsStringSync();
        for (final m in _push.allMatches(src)) {
          final cls = m.group(1)!;
          if (cls == 'LightPage') {
            final child = _wrap.firstMatch(src.substring(m.start))?.group(1);
            if (child == null) {
              bad.add('${f.path}: LightPage 裡面看不出包的是誰');
            } else if (_dark.contains(child) || _editors.contains(child)) {
              bad.add('${f.path}: $child 是深色頁，不該包 LightPage');
            } else if (!_light.contains(child)) {
              bad.add('${f.path}: $child 沒歸類（見檔頭的 _light／_dark）');
            }
          } else if (_light.contains(cls)) {
            bad.add('${f.path}: $cls 是淺色頁，推的時候沒包 LightPage');
          }
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });
  });
}
