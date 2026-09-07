// 範本夾長按選單的兩件事：
//
//   1. 改名：對話框收起的時候 TextEditingController 不能已經被 dispose。
//      以前是 `await showDialog` 一回來就 `ctrl.dispose()`——可是 pop 的
//      future 在收起動畫一開始就完成了，接下來的幾格 TextField 還活著，
//      失焦寫回 controller.value 就炸「A TextEditingController was used
//      after being disposed」。release 版 assert 拿掉不會當，但 debug／
//      profile 每改一次名就噴一次紅字，容易把真的錯誤蓋掉。
//   2. 「刪除」那列用的要是淺色佈景的 error 色，不是深色頁的 #FF6B6B
//      （白底上對比只有 2.8:1）
//
// 平台釘在 iOS：Android 的 M3 水波是 InkSparkle，要 ink_sparkle.frag 這個
// shader 資產；--no-test-assets 下沒有它，每按一下就噴一則雜訊。
// 復原一定要在測試主體裡做（框架在 tearDown 之前就會檢查 debug 變數）
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/presets_screen.dart';
import 'package:markcut/services/preset_store.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/watermark_layer.dart';

/// SharedPreferences 是真的非同步，要 runAsync 才推得動
Future<void> _settle(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _pump(WidgetTester t) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      home: const LightPage(child: PresetsScreen()),
    ),
  );
  await _settle(t);
  expect(find.byType(WatermarkLayer), findsOneWidget, reason: '範本沒載進來');
}

Future<void> _onIOS(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// 長按那張範本卡，等選單長出來
Future<void> _openActions(WidgetTester t) async {
  await t.longPress(find.byType(WatermarkLayer));
  await _settle(t);
  expect(find.text('改名'), findsOneWidget, reason: '長按沒有開選單');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'wm_presets_seeded_v1': true,
      'wm_presets_seeded_v2': true,
      'wm_presets_seeded_v3': true,
      'wm_presets_seeded_v4': true,
      'wm_presets_v1': [
        WatermarkPreset(
          name: '舊名',
          settings: WatermarkSettings()..text.text = '@x',
        ).encode(),
      ],
    });
  });

  testWidgets(
    '改名：按「確定」之後的每一格都不能有例外，名字要真的改掉',
    (t) => _onIOS(() async {
      await _pump(t);
      await _openActions(t);
      await t.tap(find.text('改名'));
      await _settle(t);
      expect(find.byType(TextField), findsOneWidget, reason: '改名對話框沒開');

      await t.enterText(find.byType(TextField), '新名字');
      await t.tap(find.text('確定'));
      // 對話框的 future 在收起動畫一開始就完成了；接下來的幾格 TextField
      // 還活著、失焦時會寫回 controller——那幾格一格都不能炸
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 50));
        expect(t.takeException(), isNull, reason: '按確定之後第 $i 格丟了例外');
      }
      await _settle(t, 20);

      expect([for (final p in await PresetStore.load()) p.name], ['新名字']);
      expect(find.text('已改名為「新名字」'), findsOneWidget, reason: '沒有提示改好了');
      await t.pump(const Duration(seconds: 3)); // 提示的計時器要跑完
      expect(t.takeException(), isNull);
    }),
  );

  testWidgets(
    '改名對話框按取消：不改名、也不炸',
    (t) => _onIOS(() async {
      await _pump(t);
      await _openActions(t);
      await t.tap(find.text('改名'));
      await _settle(t);
      await t.tap(find.text('取消'));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 50));
        expect(t.takeException(), isNull, reason: '按取消之後第 $i 格丟了例外');
      }
      await _settle(t);
      expect([for (final p in await PresetStore.load()) p.name], ['舊名']);
    }),
  );

  testWidgets(
    '長按選單的「刪除」用淺色佈景的 error 色',
    (t) => _onIOS(() async {
      await _pump(t);
      await _openActions(t);

      final ctx = t.element(find.text('刪除'));
      expect(Theme.of(ctx).brightness, Brightness.light);
      final error = Theme.of(ctx).colorScheme.error;
      expect(
        t.widget<Text>(find.text('刪除')).style?.color,
        error,
        reason: '白底上用了深色頁的 #FF6B6B（對比 2.8:1）',
      );
      expect(t.widget<Icon>(find.byIcon(Icons.delete_outline)).color, error);
      expect(t.takeException(), isNull);
    }),
  );
}
