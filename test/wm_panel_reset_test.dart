// 文字卡移除回正按鈕、保留字體空間；圖片卡仍保留回正功能。
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

  testWidgets('文字卡移除顏文字旁的重設按鈕，字型選單保有寬度', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WatermarkPanel(settings: WatermarkSettings(), onChanged: () {}),
        ),
      ),
    );
    await _settle(t);
    await t.tap(find.text('文字').first);
    await _settle(t);
    expect(find.byTooltip(_tip), findsNothing);
    final dropdown = find.byType(DropdownButton<String>);
    expect(t.getSize(dropdown).width, greaterThan(90));
    expect(t.widget<DropdownButton<String>>(dropdown).menuWidth, 280);
    expect(t.takeException(), isNull);
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
