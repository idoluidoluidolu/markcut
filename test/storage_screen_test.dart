import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/screens/storage_screen.dart';
import 'package:markcut/services/blob_store.dart';
import 'package:markcut/theme.dart';

void main() {
  testWidgets(
    'category tiles open their lists; nothing to clean leaves the pill disabled',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      BlobStore.resetForTest();
      final opened = <String>[];
      await t.pumpWidget(
        MaterialApp(
          theme: buildStudioTheme(),
          home: LightPage(
            child: StorageScreen(
              openDrafts: () async {
                opened.add('drafts');
              },
              openGifs: () async {
                opened.add('gifs');
              },
              openPresets: () async {
                opened.add('presets');
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('容量'), findsOneWidget);
      for (final title in ['草稿', 'GIF', '範本']) {
        await t.tap(find.text(title));
        await t.pumpAndSettle();
      }
      expect(opened, ['drafts', 'gifs', 'presets']);
      // 貼圖沒有自己的清單頁：只標多大，點了不開任何東西
      await t.tap(find.text('貼圖'));
      await t.pumpAndSettle();
      expect(opened, hasLength(3));

      final button = find.byKey(const ValueKey('clear-storage-cache'));
      await t.scrollUntilVisible(button, 150);
      expect(t.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('已清理'), findsOneWidget);
      expect(find.text('縮圖 0 MB · 轉檔 0 MB'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('text scale 2: tiles grow instead of overflowing', (t) async {
    SharedPreferences.setMockInitialValues({});
    BlobStore.resetForTest();
    t.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        home: LightPage(
          child: StorageScreen(
            openDrafts: () async {},
            openGifs: () async {},
            openPresets: () async {},
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final button = find.byKey(const ValueKey('clear-storage-cache'));
    await t.scrollUntilVisible(button, 150);
    expect(t.takeException(), isNull);
  });
}
