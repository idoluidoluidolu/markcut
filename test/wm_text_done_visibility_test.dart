// 浮水印文字的「完成」只在打字時出現（使用者指定：從文字編輯出來就收掉、
// 進去再開）。位置留著：收掉的那一刻鍵盤可能還沒收完，版面一動畫面就跳
//（batch_logo_drag_test 守的那件事），所以只是看不到、按不到
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/widgets/watermark_panel.dart';

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('完成：沒在打字看不到也按不到，點輸入框才出現，按完成又收掉；輸入框一格都不動', (
    t,
  ) async {
    // 夠高：整張文字卡都在畫面內，點輸入框不會為了露出游標而捲動
    t.view.physicalSize = const Size(390, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final settings = WatermarkSettings();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WatermarkPanel(settings: settings, onChanged: () {}),
        ),
      ),
    );
    await _settle(t);
    await t.tap(find.text('文字').first);
    await _settle(t);
    final input = find.byKey(const ValueKey('watermark-text-input'));
    final done = find.byKey(const ValueKey('watermark-text-done'));
    expect(input, findsOneWidget);
    expect(done.hitTestable(), findsNothing, reason: '還沒進文字編輯就不該有完成');
    final idle = t.getRect(input);

    await t.tap(input);
    await _settle(t);
    expect(t.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    expect(done.hitTestable(), findsOneWidget, reason: '進文字編輯就出現');
    expect(t.getRect(input), idle, reason: '完成出現不能推動輸入框');

    await t.enterText(input, '收掉測試');
    await _settle(t);
    await t.tap(done);
    await _settle(t);
    expect(t.widget<TextField>(input).focusNode!.hasFocus, isFalse);
    expect(done.hitTestable(), findsNothing, reason: '從文字編輯出來就收掉');
    expect(t.getRect(input), idle, reason: '收掉不能讓輸入框跳位');
    expect(settings.text.text, '收掉測試');

    // 再進去又開
    await t.tap(input);
    await _settle(t);
    expect(done.hitTestable(), findsOneWidget, reason: '再進文字編輯又出現');
    expect(t.takeException(), isNull);
  });
}
