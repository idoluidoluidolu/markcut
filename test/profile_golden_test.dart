// 個人中心的畫面快照（golden）。
//
// 產生／更新圖片：
//   flutter test --update-goldens test/profile_golden_test.dart
//
// 兩種狀態都要顧：有東西的時候（範本磚＋草稿卡）與全空的時候。
// 空狀態特別容易在改版時被忘掉，golden 對不上就會失敗
//
// 尺寸照真的 iPhone 14（390×844，瀏海 47＋home 條 34）：這一頁要
// 「一頁裝得下」，而少算的那 81pt 安全區正好就是它裝不下的原因——
// 沒有安全區的畫布拍出來的是一張永遠不會發生的畫面。
//
// pump 也要等：SharedPreferences 是真的非同步，只 pump 一次的話
// _reload 的 setState 還沒回來，「有範本、有草稿」那張拍到的其實是
// 空狀態（這支測試以前就是這樣，兩張 golden 一模一樣）
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/screens/video_editor_screen.dart' show kDraftKey;
import 'package:markcut/screens/photo_editor_screen.dart' show kPhotoDraftKey;

/// 真的 iPhone 14：邏輯 390×844、dpr 3，安全區用實體像素給
void _iphone14(WidgetTester t) {
  t.view.devicePixelRatio = 3.0;
  t.view.physicalSize = const Size(1170, 2532);
  t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
  t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
  addTearDown(t.view.reset);
}

/// 讓 SharedPreferences／草稿清單真的讀完（見檔頭）
Future<void> _settle(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final (family, path) in const [
      ('NotoSansTC', 'assets/fonts/NotoSansTC.ttf'),
      ('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
  });

  testWidgets('個人中心（有範本、有草稿）', (tester) async {
    final daily = WatermarkPreset(
      name: '日常',
      settings: WatermarkSettings()..text.text = '@我的浮水印',
    );
    final work = WatermarkPreset(
      name: '接案',
      settings: WatermarkSettings()..text.text = '© STUDIO',
    );
    SharedPreferences.setMockInitialValues({
      'wm_presets_v1': [daily.encode(), work.encode()],
      'wm_presets_seeded_v1': true,
      kDraftKey: jsonEncode({
        'savedAt': DateTime.now()
            .subtract(const Duration(minutes: 3))
            .toIso8601String(),
        'clips': [
          {'id': 1},
        ],
      }),
      kPhotoDraftKey: jsonEncode({
        'savedAt': DateTime.now()
            .subtract(const Duration(days: 1))
            .toIso8601String(),
        'photo': '/tmp/x.jpg',
      }),
    });

    _iphone14(tester);
    await tester.pumpWidget(
      MaterialApp(
        // App 的預設佈景是深色；淺色是在 route 層包上去的，
        // 測試也照同一種方式包，不然量到的不是真的長相
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: const LightPage(child: ProfileScreen()),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/profile.png'),
    );
  });

  testWidgets('個人中心（空的）', (tester) async {
    SharedPreferences.setMockInitialValues({'wm_presets_seeded_v1': true});
    _iphone14(tester);
    await tester.pumpWidget(
      MaterialApp(
        // App 的預設佈景是深色；淺色是在 route 層包上去的，
        // 測試也照同一種方式包，不然量到的不是真的長相
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: const LightPage(child: ProfileScreen()),
      ),
    );
    await _settle(tester);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/profile_empty.png'),
    );
  });
}
