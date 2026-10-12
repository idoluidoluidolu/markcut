// 套範本＝自動換成「套用當下」的時間（10-12 使用者指定）。這支盯三件事：
//   1. refreshTimeStamps 只換「時間」那顆的寫法（2026/10/12 15:20）：一段裡
//      有幾個換幾個；別種日期寫法、前後還接著數字的都不動
//   2. 面板：範本存的是 10/01 09:00 → 挑選彈窗的卡片已經畫成現在、點下去
//      套上來的是現在、先拍復原快照；範本清單裡那一份沒被改到，隔天再套
//      一次換成隔天的時間
//   3. 沒有時間的範本照原樣套
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/preset_store.dart';
import 'package:markcut/widgets/text_insert_bar.dart';
import 'package:markcut/widgets/watermark_layer.dart';
import 'package:markcut/widgets/watermark_panel.dart';

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 60));
  }
}

const _stored = '@我的浮水印\n2026/10/01 09:00';

void main() {
  setUp(() => insertTimeNow = () => DateTime(2026, 10, 12, 15, 20, 45));
  tearDown(() => insertTimeNow = DateTime.now);

  test('只換「時間」那種寫法，一段裡有幾個換幾個', () {
    const now = '2026/10/12 15:20';
    expect(refreshTimeStamps(_stored, now), '@我的浮水印\n$now');
    expect(refreshTimeStamps('拍攝於 2026/10/01 09:00 台北', now), '拍攝於 $now 台北');
    expect(
      refreshTimeStamps('2026/10/01 09:00\n2025/01/02 03:04', now),
      '$now\n$now',
    );
    // 別種寫法、只有日期、只有時間：不動
    for (final keep in const [
      '2026-10-01 09:00',
      '10/01 09:00',
      '2026/10/01',
      '09:00',
      '2026/10/1 9:00',
    ]) {
      expect(refreshTimeStamps(keep, now), keep, reason: keep);
    }
    // 前後還接著數字的不是「時間」那顆加的
    expect(refreshTimeStamps('12026/10/01 09:001', now), '12026/10/01 09:001');
    expect(hasTimeStamp('@我的浮水印'), isFalse);
    expect(hasTimeStamp(_stored), isTrue);
  });

  testWidgets('套範本：卡片跟套上來的都是現在的時間，範本本身不動', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final timed = WatermarkPreset(
      name: '帶時間',
      settings: WatermarkSettings(texts: [TextMark(text: _stored)]),
    );
    final plain = WatermarkPreset(
      name: '沒時間',
      settings: WatermarkSettings(texts: [TextMark(text: '@純文字')]),
    );
    SharedPreferences.setMockInitialValues({
      'wm_presets_v1': [timed.encode(), plain.encode()],
    });
    final settings = WatermarkSettings();
    final before = settings.text.text;
    WatermarkSettings? undo;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WatermarkPanel(
            settings: settings,
            onBeforeChange: () => undo = settings.copy(),
            onChanged: () {},
          ),
        ),
      ),
    );
    await _settle(t);

    /// 挑選彈窗裡每一張卡畫的那一份
    List<WatermarkLayer> cards() => t
        .widgetList<WatermarkLayer>(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(WatermarkLayer),
          ),
        )
        .toList();

    Future<void> applyTimed(String expectText) async {
      await t.tap(find.text('範本').first);
      await _settle(t);
      expect(find.text('選擇範本'), findsOneWidget);
      final texts = cards().map((c) => c.settings.text.text).toList();
      expect(
        texts,
        containsAll([expectText, '@純文字']),
        reason: '卡片要畫成套上去的樣子（時間是現在）',
      );
      final card = cards().firstWhere(
        (c) => c.settings.text.text == expectText,
      );
      await t.tap(find.byWidget(card));
      await _settle(t);
    }

    await applyTimed('@我的浮水印\n2026/10/12 15:20');
    expect(settings.text.text, '@我的浮水印\n2026/10/12 15:20');
    expect(undo!.text.text, before, reason: '套範本之前要先拍復原快照');

    // 範本清單裡那一份還是存的那一刻
    final saved = await t.runAsync(PresetStore.load);
    expect(
      saved!.firstWhere((p) => p.name == '帶時間').settings.text.text,
      _stored,
      reason: '套範本把範本本身的時間也改掉了',
    );

    // 隔天再套一次：換成隔天的時間
    insertTimeNow = () => DateTime(2026, 10, 13, 8, 5);
    await applyTimed('@我的浮水印\n2026/10/13 08:05');
    expect(settings.text.text, '@我的浮水印\n2026/10/13 08:05');

    // 沒有時間的範本照原樣套
    await t.tap(find.text('範本').first);
    await _settle(t);
    await t.tap(
      find.byWidget(cards().firstWhere((c) => c.settings.text.text == '@純文字')),
    );
    await _settle(t);
    expect(settings.text.text, '@純文字');
    expect(t.takeException(), isNull);
  });
}
