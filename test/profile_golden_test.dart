// 個人中心的畫面快照（golden）。
//
// 產生／更新圖片：
//   flutter test --update-goldens test/profile_golden_test.dart
//
// 兩種狀態都要顧：有東西的時候（範本磚＋草稿卡）與全空的時候。
// 空狀態特別容易在改版時被忘掉，golden 對不上就會失敗
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/screens/video_editor_screen.dart' show kDraftKey;
import 'package:markcut/screens/photo_editor_screen.dart' show kPhotoDraftKey;

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

    await tester.binding.setSurfaceSize(const Size(390, 780));
    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ProfileScreen(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/profile.png'),
    );
  });

  testWidgets('個人中心（空的）', (tester) async {
    SharedPreferences.setMockInitialValues({'wm_presets_seeded_v1': true});
    await tester.binding.setSurfaceSize(const Size(390, 780));
    await tester.pumpWidget(
      const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ProfileScreen(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/profile_empty.png'),
    );
  });
}
