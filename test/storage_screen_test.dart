import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:markcut/screens/storage_screen.dart';
import 'package:markcut/services/blob_store.dart';

void main() {
  testWidgets(
    'storage categories open their managers and empty cleanup is disabled',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      BlobStore.resetForTest();
      final opened = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: StorageScreen(
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
      );
      await t.pumpAndSettle();
      for (final title in ['草稿', 'GIF', '範本']) {
        await t.tap(find.text(title));
        await t.pumpAndSettle();
      }
      expect(opened, ['drafts', 'gifs', 'presets']);
      final button = find.byKey(const ValueKey('clear-storage-cache'));
      await t.scrollUntilVisible(button, 150);
      expect(t.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('預覽縮圖暫存'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
