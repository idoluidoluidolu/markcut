import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/presets_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/services/gif_store.dart';
import 'package:markcut/services/preset_store.dart';
import 'package:markcut/theme.dart';

const _gif = <int>[
  71,
  73,
  70,
  56,
  57,
  97,
  1,
  0,
  1,
  0,
  128,
  0,
  0,
  0,
  0,
  0,
  255,
  255,
  255,
  33,
  249,
  4,
  1,
  10,
  0,
  1,
  0,
  44,
  0,
  0,
  0,
  0,
  1,
  0,
  1,
  0,
  0,
  2,
  2,
  76,
  1,
  0,
  59,
];

Future<void> _settle(WidgetTester t, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 30));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<File> gifs;
  late List<String> presets;
  setUp(() {
    presets = [
      for (final name in ['甲', '乙', '丙'])
        WatermarkPreset(name: name, settings: WatermarkSettings()).encode(),
    ];
    SharedPreferences.setMockInitialValues({
      for (var i = 1; i <= 4; i++) 'wm_presets_seeded_v$i': true,
      'wm_presets_v1': presets,
    });
    root = Directory.systemTemp.createTempSync('markcut_library_delete_');
    final dir = Directory('${root.path}${Platform.pathSeparator}gifs')
      ..createSync();
    gifs = [
      for (var i = 0; i < 3; i++)
        File('${dir.path}${Platform.pathSeparator}$i.gif')
          ..writeAsBytesSync(_gif),
    ];
    GifStore.documentsDirOverride = root;
  });
  tearDown(() {
    GifStore.documentsDirOverride = null;
    root.deleteSync(recursive: true);
  });

  test(
    'bulk preset deletion preserves unselected and malformed rows',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('wm_presets_v1', [
        ...presets,
        'legacy-invalid-row',
      ]);
      expect(await PresetStore.removeMany({'甲', '丙'}), isTrue);
      expect(prefs.getStringList('wm_presets_v1'), [
        presets[1],
        'legacy-invalid-row',
      ]);
    },
  );

  test('bulk GIF deletion only removes selected managed files', () async {
    final outside = File('${root.path}/original.gif')..writeAsBytesSync(_gif);
    expect(
      await GifStore.removeMany({gifs[0].path, gifs[2].path, outside.path}),
      {outside.path},
    );
    expect(gifs[0].existsSync(), isFalse);
    expect(gifs[1].readAsBytesSync(), _gif);
    expect(gifs[2].existsSync(), isFalse);
    expect(outside.readAsBytesSync(), _gif);
    expect(await GifStore.removeMany({gifs[0].path}), isEmpty);
  });

  for (final isGif in [false, true]) {
    testWidgets(
      '${isGif ? 'GIF' : 'preset'} multi-select, cancel, back, delete',
      (t) async {
        await t.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => t.binding.setSurfaceSize(null));
        await t.pumpWidget(
          MaterialApp(
            theme: buildStudioTheme().copyWith(platform: TargetPlatform.iOS),
            home: LightPage(
              child: isGif ? const GifsScreen() : const PresetsScreen(),
            ),
          ),
        );
        await _settle(t);
        await t.tap(find.text('選取'));
        await t.pumpAndSettle();
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(
          t
              .widget<FilledButton>(find.widgetWithText(FilledButton, '刪除 (0)'))
              .onPressed,
          isNull,
        );
        await t.tap(find.text('全選'));
        await t.pump();
        expect(find.text('已選 3 項'), findsOneWidget);
        await t.tap(find.text('取消全選'));
        await t.pump();
        expect(find.text('已選 0 項'), findsOneWidget);
        // Back exits selection rather than losing the library page.
        await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
        await t.pump();
        expect(find.text('選取'), findsOneWidget);
        await t.tap(find.text('選取'));
        await t.pump();
        await t.tap(find.text('全選'));
        await t.pump();
        await t.tap(
          find.byKey(ValueKey(isGif ? 'gif-${gifs[1].path}' : 'preset-乙')),
        );
        await t.pump();
        expect(find.text('已選 2 項'), findsOneWidget);
        expect(find.byType(PageView), findsNothing);
        await t.tap(find.text('刪除 (2)'));
        await _settle(t, 4);
        final dialog = find.byType(Dialog);
        await t.tap(find.descendant(of: dialog, matching: find.text('取消')));
        await _settle(t, 4);
        expect(find.text('已選 2 項'), findsOneWidget);
        expect(gifs.every((f) => f.existsSync()), isTrue);
        expect((await PresetStore.load()).length, 3);
        await t.tap(find.text('刪除 (2)'));
        await _settle(t, 4);
        await t.tap(find.widgetWithText(FilledButton, '刪除'));
        await _settle(t);
        if (isGif) {
          expect(gifs[0].existsSync(), isFalse);
          expect(gifs[1].existsSync(), isTrue);
          expect(gifs[2].existsSync(), isFalse);
        } else {
          expect((await PresetStore.load()).map((p) => p.name), ['乙']);
        }
        expect(find.text('選取'), findsOneWidget);
        expect(find.text('已選 2 項'), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await _settle(t, 4);
      },
    );
  }
}
