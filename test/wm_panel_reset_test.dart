// 面板的「回正中央、恢復預設大小」：拿掉預覽上的雙擊之後，拖出畫面外的
// 部件靠這顆撿回來（文字卡、圖片卡各一顆；平鋪中不出現）
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/widgets/watermark_panel.dart';

Future<Uint8List> _png(int side) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final img = await rec.endRecording().toImage(side, side);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 30));
  }
}

const _tip = '回正中央、恢復預設大小';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('文字卡：按了回到 (0.5,0.5)、預設字級，並拍一次快照', (t) async {
    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final s = WatermarkSettings();
    s.text
      ..x = 1.3
      ..y = -0.2
      ..sizeFrac = 0.5;
    var before = 0, changed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WatermarkPanel(
            settings: s,
            onChanged: () => changed++,
            onBeforeChange: () => before++,
          ),
        ),
      ),
    );
    await _settle(t);
    await t.tap(find.text('文字').first);
    await _settle(t);
    final btn = find.byTooltip(_tip);
    expect(btn, findsOneWidget);
    await t.tap(btn);
    await _settle(t);
    expect((s.text.x, s.text.y), (0.5, 0.5));
    expect(s.text.sizeFrac, TextMark().sizeFrac);
    expect(before, 1, reason: '一次離散改動＝一張快照');
    expect(changed, 1);
  });

  testWidgets('圖片卡：同一顆；平鋪中不出現', (t) async {
    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    late Uint8List png;
    await t.runAsync(() async => png = await _png(40));
    final s = WatermarkSettings();
    s.logo
      ..enabled = true
      ..bytesValue = png
      ..x = 0.05
      ..y = 0.95
      ..sizeFrac = 1.2;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WatermarkPanel(settings: s, onChanged: () {}),
        ),
      ),
    );
    await _settle(t);
    await t.tap(find.text('圖片').first);
    await _settle(t);
    await t.tap(find.byTooltip(_tip));
    await _settle(t);
    expect((s.logo.x, s.logo.y), (0.5, 0.5));
    expect(s.logo.sizeFrac, LogoMark().sizeFrac);

    // 開平鋪：位置無意義，按鈕收起來
    await t.tap(find.byType(Switch).first);
    await _settle(t);
    expect(s.logo.tiled, isTrue);
    expect(find.byTooltip(_tip), findsNothing);
  });
}
