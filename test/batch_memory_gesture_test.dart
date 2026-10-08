import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/widgets/watermark_layer.dart';
import 'package:markcut/widgets/watermark_panel.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
    'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=';

Future<void> _open(WidgetTester t, {bool logos = false}) async {
  SharedPreferences.setMockInitialValues({});
  await t.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final settings = WatermarkSettings();
  if (logos) {
    settings.logo
      ..enabled = true
      ..b64 = base64Encode(base64Decode(_png));
    settings.logos.add(
      LogoMark(enabled: true, b64: base64Encode(base64Decode(_png)), x: 0.2),
    );
  }
  await t.pumpWidget(
    MaterialApp(
      home: BatchWatermarkScreen(
        files: [XFile.fromData(base64Decode(_png), name: 'photo.png')],
        restore: {'settings': settings.toJson()},
      ),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

WatermarkLayer _layer(WidgetTester t) =>
    t.widget<WatermarkLayer>(find.byType(WatermarkLayer));

void main() {
  tearDown(() => debugOnRebuildDirtyWidget = null);

  testWidgets(
    'batch undo shares all Logo payloads while isolating mutable marks',
    (t) async {
      await _open(t, logos: true);
      final initial = _layer(t).settings;
      final payloads = initial.logos.map((l) => l.b64).toList();
      final originalX = initial.logos.map((l) => l.x).toList();
      _layer(t).onDragStart!();
      initial.logos[0].x = 0.8;
      initial.logos[1].x = 0.7;
      _layer(t).onChanged();
      await t.pump();
      await t.tap(find.byIcon(Icons.undo));
      await t.pump();
      var restored = _layer(t).settings;
      expect(restored.logos.map((l) => l.x), originalX);
      for (var i = 0; i < payloads.length; i++) {
        expect(
          identical(restored.logos[i].b64, payloads[i]),
          isTrue,
          reason:
              'undo must retain the original immutable image, not a JSON copy',
        );
      }
      await t.tap(find.byIcon(Icons.redo));
      await t.pump();
      restored = _layer(t).settings;
      expect(restored.logos.map((l) => l.x), [0.8, 0.7]);
      expect(identical(restored.logos[0].b64, payloads[0]), isTrue);
      await t.tap(find.byIcon(Icons.undo));
      await t.pump();
      expect(_layer(t).settings.logos.map((l) => l.x), originalX);
      await t.pumpWidget(const SizedBox());
      expect(t.takeException(), isNull);
    },
  );

  for (final selected in [false, true]) {
    testWidgets('batch drag stays within preview (selected=$selected)', (
      t,
    ) async {
      await _open(t);
      if (selected) {
        _layer(t).onSelectPart!(WmPart.text);
        await t.pump();
      }
      final before = _layer(t).settings.text.x;
      final sync = t
          .widget<WatermarkPanel>(find.byType(WatermarkPanel))
          .syncVersion;
      final g = await t.startGesture(
        t.getRect(find.byType(WatermarkLayer)).center,
      );
      // 觸控的拖曳門檻是 36px（kPanSlop）：先越過門檻讓拖曳成立，
      // 再動一下讓第一次更新把「上一步」拍掉（會亮上一步鈕＝整頁一次），
      // 之後才開始數
      await g.moveBy(const Offset(40, 0));
      await t.pump();
      await g.moveBy(const Offset(3, 0));
      await t.pump();
      var rootBuilds = 0;
      var panelBuilds = 0;
      var previewBuilds = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e.widget is BatchWatermarkScreen) rootBuilds++;
        if (e.widget is WatermarkPanel) panelBuilds++;
        if (e.widget is WatermarkLayer) previewBuilds++;
      };
      for (var i = 0; i < 8; i++) {
        await g.moveBy(const Offset(3, 1));
        await t.pump(const Duration(milliseconds: 16));
      }
      debugOnRebuildDirtyWidget = null;
      expect(_layer(t).settings.text.x, greaterThan(before));
      expect(rootBuilds, 0);
      expect(panelBuilds, 0);
      expect(previewBuilds, greaterThan(0));
      await g.up();
      await t.pump();
      // 放手整頁對上一次，但不能走「復原同步」：那會把面板選中的範本
      // 取消、輸入框重設
      expect(
        t.widget<WatermarkPanel>(find.byType(WatermarkPanel)).syncVersion,
        sync,
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('batch pinch updates preview without rebuilding settings panel', (
    t,
  ) async {
    await _open(t);
    final center = t.getRect(find.byType(WatermarkLayer)).center;
    final a = await t.startGesture(center + const Offset(-80, 0));
    final b = await t.startGesture(center + const Offset(80, 0));
    await a.moveBy(const Offset(-4, 0));
    await t.pump();
    final before = _layer(t).settings.text.sizeFrac;
    var rootBuilds = 0;
    var panelBuilds = 0;
    debugOnRebuildDirtyWidget = (e, _) {
      if (e.widget is BatchWatermarkScreen) rootBuilds++;
      if (e.widget is WatermarkPanel) panelBuilds++;
    };
    for (var i = 0; i < 8; i++) {
      await a.moveBy(const Offset(-2, 0));
      await b.moveBy(const Offset(2, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    debugOnRebuildDirtyWidget = null;
    expect(_layer(t).settings.text.sizeFrac, greaterThan(before));
    expect(rootBuilds, 0);
    expect(panelBuilds, 0);
    await a.up();
    await b.up();
    await t.pump();
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
