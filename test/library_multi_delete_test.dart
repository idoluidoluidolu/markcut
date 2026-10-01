// 「查看全部」三頁（草稿／我的 GIF／範本）的刪除：
//
//   1. 批次刪除：右上「批次刪除」→ 左上換「取消」、右上「全選」，每一格
//      標出多大；選了至少一個，底下的紅鈕「刪除 N 個 · 省下 X」才浮上來。
//      按返回是先退出批次刪除，不是離開這一頁。
//   2. 長按一格：背景壓暗、旁邊跳小選單（不是整頁的確認對話框），
//      「取消」什麼都不動，「刪除」只刪那一個。
//   3. 從「容量與清理」點進來（batch: true）一進來就是批次刪除。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/photo_editor_screen.dart' show kPhotoDraftKey;
import 'package:markcut/screens/presets_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/gif_store.dart';
import 'package:markcut/services/preset_store.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/library_selection.dart';

/// 最小的合法 GIF（1×1，一格）
const _gif = <int>[
  71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, //
  255, 255, 255, 33, 249, 4, 1, 10, 0, 1, 0, 44, 0, 0, 0, 0, //
  1, 0, 1, 0, 0, 2, 2, 76, 1, 0, 59,
];

Future<void> _settle(WidgetTester t, [int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _pumpPage(WidgetTester t, Widget page) async {
  await t.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme().copyWith(platform: TargetPlatform.iOS),
      home: LightPage(child: page),
    ),
  );
  await _settle(t);
}

/// 底下的紅鈕
LibraryDeleteDock _dock(WidgetTester t) =>
    t.widget<LibraryDeleteDock>(find.byType(LibraryDeleteDock));

Finder get _dockButton => find.descendant(
  of: find.byType(LibraryDeleteDock),
  matching: find.byType(FilledButton),
);

/// 長按選單本體（176 寬的那一塊）
Finder _menuOf(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 176),
);

/// 長按 [tile]，等選單長出來；回傳那一格的位置
Future<Rect> _longPress(WidgetTester t, Finder tile, String title) async {
  final rect = t.getRect(tile);
  await t.longPress(tile);
  await t.pumpAndSettle();
  expect(find.text(title), findsOneWidget, reason: '長按沒有跳選單');
  expect(find.byType(Dialog), findsNothing, reason: '跳的是整頁的確認對話框');
  // 背景壓暗
  final scrim = t.widget<ModalBarrier>(find.byType(ModalBarrier).last);
  expect(scrim.color, Colors.black.withValues(alpha: 0.5));
  // 選單在那一格旁邊，沒蓋住它
  final menu = t.getRect(_menuOf(title));
  expect(
    menu.left >= rect.right || menu.right <= rect.left,
    isTrue,
    reason: '選單蓋住了那一格（格 $rect，選單 $menu）',
  );
  return rect;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<File> gifs;
  late List<String> presets;

  /// 種 [n] 份影片草稿（只有內容鍵，索引會自己重建），[photo] 再加一份
  /// 照片草稿
  void seedDrafts(int n, {bool photo = false}) {
    SharedPreferences.setMockInitialValues({
      for (var i = 1; i <= 4; i++) 'wm_presets_seeded_v$i': true,
      for (var i = 0; i < n; i++)
        'project_data_d$i': jsonEncode({
          'savedAt': DateTime(2026, 9, 20 - i).toIso8601String(),
          'clips': [
            {'id': 1},
          ],
        }),
      if (photo)
        kPhotoDraftKey: jsonEncode({
          'photo': '${root.path}${Platform.pathSeparator}x.png',
          'savedAt': DateTime(2026, 9, 20).toIso8601String(),
        }),
    });
  }

  setUp(() {
    BlobStore.resetForTest();
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
    // 刪草稿會連帶清轉檔暫存、算容量：都指到這次的暫存資料夾
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });
  tearDown(() {
    GifStore.documentsDirOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
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

  test('delete label: count, then what it frees', () {
    expect(libraryDeleteLabel(2, '份', null), '刪除 2 份');
    expect(
      libraryDeleteLabel(2, '份', 1536 * 1024 * 1024),
      '刪除 2 份 · 省下 1.5 GB',
    );
    // 「不到 1 MB」是中文開頭：前面不空格
    expect(libraryDeleteLabel(3, '個', 4096), '刪除 3 個 · 省下不到 1 MB');
  });

  for (final isGif in [false, true]) {
    testWidgets(
      '${isGif ? 'GIF' : 'preset'} batch delete: select all, cancel, back, delete',
      (t) async {
        await _pumpPage(t, isGif ? const GifsScreen() : const PresetsScreen());
        await t.tap(find.text('批次刪除'));
        await t.pumpAndSettle();
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.text('取消'), findsOneWidget, reason: '左上沒有換成取消');
        // 每一格標多大（都很小）
        expect(find.text('不到 1 MB'), findsNWidgets(3));
        // 一個都沒選：紅鈕不浮上來
        expect(_dock(t).visible, isFalse);
        await t.tap(find.text('全選'));
        await t.pump();
        expect(_dock(t).visible, isTrue);
        expect(_dock(t).label, '刪除 3 個 · 省下不到 1 MB');
        await t.tap(find.text('取消全選'));
        await t.pump();
        expect(_dock(t).visible, isFalse);
        // Back exits selection rather than losing the library page.
        await t.state<NavigatorState>(find.byType(Navigator)).maybePop();
        await t.pumpAndSettle();
        expect(find.text('批次刪除'), findsOneWidget);
        expect(find.text('不到 1 MB'), findsNothing);
        await t.tap(find.text('批次刪除'));
        await t.pump();
        await t.tap(find.text('全選'));
        await t.pump();
        await t.tap(
          find.byKey(ValueKey(isGif ? 'gif-${gifs[1].path}' : 'preset-乙')),
        );
        // 紅鈕滑上來要 260ms：滑完才按得到
        await t.pumpAndSettle();
        expect(_dock(t).label, startsWith('刪除 2 個'));
        expect(find.byType(PageView), findsNothing);
        await t.tap(_dockButton);
        await _settle(t, 4);
        final dialog = find.byType(Dialog);
        await t.tap(find.descendant(of: dialog, matching: find.text('取消')));
        await _settle(t, 4);
        expect(_dock(t).label, startsWith('刪除 2 個'));
        expect(gifs.every((f) => f.existsSync()), isTrue);
        expect((await PresetStore.load()).length, 3);
        await t.tap(_dockButton);
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
        expect(find.text('批次刪除'), findsOneWidget);
        expect(_dock(t).visible, isFalse);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await _settle(t, 4);
      },
    );
  }

  testWidgets('GIF long-press: menu beside the tile; 取消 keeps, 刪除 removes', (
    t,
  ) async {
    await _pumpPage(t, const GifsScreen());
    final tile = find.byKey(ValueKey('gif-${gifs[1].path}'));
    await _longPress(t, tile, '刪除這個 GIF？');
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(find.text('刪除這個 GIF？'), findsNothing);
    expect(gifs.every((f) => f.existsSync()), isTrue);

    await _longPress(t, tile, '刪除這個 GIF？');
    await t.tap(find.text('刪除'));
    await _settle(t);
    // 選單本身就是「要不要刪」：不再跳第二層確認
    expect(find.byType(Dialog), findsNothing);
    expect(gifs[1].existsSync(), isFalse, reason: '選了刪除卻沒刪');
    expect(gifs[0].existsSync() && gifs[2].existsSync(), isTrue);
    expect(tile, findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await _settle(t, 4);
  });

  testWidgets('preset long-press: 改名／刪除 beside the card; 刪除 removes', (
    t,
  ) async {
    await _pumpPage(t, const PresetsScreen());
    final card = find.byKey(const ValueKey('preset-乙'));
    await _longPress(t, card, '範本「乙」');
    expect(find.text('改名'), findsOneWidget);
    await t.tap(find.text('刪除'));
    await _settle(t);
    expect(find.byType(Dialog), findsNothing);
    expect((await PresetStore.load()).map((p) => p.name), ['甲', '丙']);
    expect(card, findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await _settle(t, 4);
  });

  testWidgets('drafts batch delete: only video drafts are picked', (t) async {
    seedDrafts(3, photo: true);
    await _pumpPage(t, const DraftsScreen());
    expect(find.text('未完成的照片'), findsOneWidget);
    await t.tap(find.text('批次刪除'));
    await t.pump();
    expect(_dock(t).visible, isFalse);
    await t.tap(find.text('全選'));
    await t.pump();
    expect(_dock(t).visible, isTrue);
    expect(_dock(t).label, startsWith('刪除 3 份'));
    // 照片草稿不進批次（各只有一份，長按就能刪）：點它不會被選進去
    //（它上面蓋著一層淡白，點到的是那一層）
    await t.tap(find.text('未完成的照片'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(_dock(t).label, startsWith('刪除 3 份'));
    await t.tap(_dockButton);
    await _settle(t, 4);
    expect(find.text('刪除 3 份草稿？'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, '刪除'));
    await _settle(t);
    expect(await DraftStore.list(), isEmpty);
    expect(find.text('未完成的照片'), findsOneWidget, reason: '照片草稿被一起刪了');
    // 影片草稿都沒了：沒有東西可以批次刪，右上那顆也收起來
    expect(find.text('批次刪除'), findsNothing);
    expect(_dock(t).visible, isFalse);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await _settle(t, 4);
  });

  testWidgets('drafts long-press: 刪除 removes only that draft', (t) async {
    seedDrafts(2, photo: true);
    await _pumpPage(t, const DraftsScreen());
    await _longPress(t, find.text('未完成的照片'), '刪除這份草稿？');
    await t.tap(find.text('刪除'));
    await _settle(t);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('未完成的照片'), findsNothing, reason: '選了刪除卻沒刪');
    expect(await DraftStore.list(), hasLength(2), reason: '影片草稿被一起刪了');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await _settle(t, 4);
  });

  // 從「容量與清理」點分類進來：一進來就是批次刪除
  for (final (name, page) in [
    ('drafts', const DraftsScreen(batch: true)),
    ('GIF', const GifsScreen(batch: true)),
    ('presets', const PresetsScreen(batch: true)),
  ]) {
    testWidgets('$name opened with batch: true starts in batch mode', (
      t,
    ) async {
      seedDrafts(2);
      if (name == 'presets') {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList('wm_presets_v1', presets);
      }
      await _pumpPage(t, page);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('全選'), findsOneWidget);
      expect(find.text('批次刪除'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(_dock(t).visible, isFalse);
      // 取消＝回到平常的查看全部，不是離開
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(find.text('批次刪除'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await _settle(t, 4);
    });
  }
}
