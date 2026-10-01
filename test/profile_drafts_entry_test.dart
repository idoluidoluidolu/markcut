// 個人中心草稿分頁的三件事：
//
//   1. 只有批次／GIF／拼圖草稿（沒有影片、照片草稿）的時候，草稿分頁照樣
//      要列出來。以前 draftCount 只算影片＋照片，這種人看到的是「還沒有
//      草稿」——而全 lib/ 只有個人中心會建 DraftsScreen，批次／GIF／拼圖
//      頁進場也不讀自己的草稿鍵，所以批次頁離開時選了「保留草稿」的人，
//      那份草稿從此沒有任何入口。
//   2. 草稿比四格多的時候，第四格是「+N 查看全部」，點下去是全部草稿的
//      瀑布流（單鍵草稿也在裡面）。
//   3. 每一種草稿格點下去都要接續自己的編輯頁。以前只有影片卡會直接開
//      專案，照片／批次／GIF／拼圖四種點下去只是進資料夾、還得再點一次
//      ——兩張相鄰的卡，一張續作、一張換頁。
//
// 順帶守「我的 GIF」右下角 ＋ 的三列面板：橫向時高度只剩 375，
// 三列（48 抓把＋3×56＋6）塞不進 9/16 的上限，面板要能捲、最後一列要
// 按得到（跟首頁的面板同一個病，見 home_screen_test）。
//
// 選取器不會被開到（卡片直接帶檔案進編輯頁），但推出去的頁會掛提示條
// 與重試計時器，跟 home_screen_test 一樣要擋掉原生外掛、結束前 drain
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/nav.dart';
import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/screens/gif_screen.dart';
import 'package:markcut/screens/photo_editor_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/services/app_media_paths.dart';

/// 8×8 PNG（測試自己寫出來，不依賴任何外部檔案）
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
    'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=';

late Directory _dir;
String _p(String name) => '${_dir.path}${Platform.pathSeparator}$name';

/// 記下被推出去的頁
class _RouteSpy extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }

  List<EditPageRoute<dynamic>> get edits =>
      pushed.whereType<EditPageRoute<dynamic>>().toList();

  /// 最後一個編輯頁的 widget（用 builder 再建一份來看它的參數）
  Widget lastEdit(WidgetTester t) =>
      edits.last.builder(t.element(find.byType(MaterialApp)));
}

/// SharedPreferences、讀檔都是真的非同步，要 runAsync 才推得動
Future<void> _settle(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// 推出去的頁會掛提示條、重試計時器；測試結束前要讓它們走完
Future<void> _drain(WidgetTester t) async {
  await t.pump(const Duration(seconds: 3));
  await t.pump(const Duration(seconds: 3));
}

/// 種「單鍵」草稿：沒有照片草稿（除非 [photo]）；影片草稿 [videos] 份
///（只有內容鍵，索引會自己重建，見 DraftStore.list）
void _seed({
  bool photo = false,
  bool batch = false,
  bool gif = false,
  bool collage = false,
  int videos = 0,
}) {
  const at = '2026-08-20T10:30:00.000';
  SharedPreferences.setMockInitialValues({
    'wm_presets_seeded_v1': true,
    'wm_presets_seeded_v2': true,
    'wm_presets_seeded_v3': true,
    'wm_presets_seeded_v4': true,
    for (var i = 0; i < videos; i++)
      'project_data_v$i': jsonEncode({
        'savedAt': at,
        'clips': [
          {'id': 1},
        ],
      }),
    if (photo)
      kPhotoDraftKey: jsonEncode({'photo': _p('a.png'), 'savedAt': at}),
    if (batch)
      kBatchDraftKey: jsonEncode({
        'files': [_p('a.png'), _p('b.png')],
        'savedAt': at,
      }),
    if (gif)
      kGifDraftKey: jsonEncode({
        'path': _p('a.mp4'),
        'name': 'a.mp4',
        'savedAt': at,
      }),
    if (collage)
      kCollageDraftKey: jsonEncode({
        'photos': [_p('a.png')],
        'savedAt': at,
      }),
  });
}

/// 真的 iPhone 14：邏輯 390×844、dpr 3、瀏海 47＋home 條 34
void _iphone14(WidgetTester t) {
  t.view.devicePixelRatio = 3.0;
  t.view.physicalSize = const Size(1170, 2532);
  t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
  t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
  addTearDown(t.view.reset);
}

/// 橫向的手機：邏輯 [w]×[h]、dpr 2、狀態列 20
void _landscape(WidgetTester t, double w, double h) {
  t.view.devicePixelRatio = 2.0;
  t.view.physicalSize = Size(w * 2, h * 2);
  t.view.padding = const FakeViewPadding(top: 40);
  t.view.viewPadding = const FakeViewPadding(top: 40);
  addTearDown(t.view.reset);
}

/// 跟 main.dart 一樣：工作室佈景的 App、頁面包 LightPage
Future<void> _pump(
  WidgetTester t,
  Widget page, {
  NavigatorObserver? spy,
}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      navigatorObservers: [?spy],
      home: LightPage(child: page),
    ),
  );
  await _settle(t);
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    _dir = Directory.systemTemp.createTempSync('markcut_profile_drafts_');
    final png = base64Decode(_pngB64);
    for (final n in const ['a.png', 'b.png']) {
      File(_p(n)).writeAsBytesSync(png);
    }
    // 影片只要「檔案存在」就好：續作只檢查檔案在不在
    File(_p('a.mp4')).writeAsBytesSync(List<int>.filled(64, 0));

    // 測試環境沒有這些原生外掛，擋掉不然推出去的頁一開就丟例外
    for (final ch in const [
      'com.llfbandit.record/messages',
      'dev.fluttercommunity.plus/wakelock',
      'flutter.arthenica.com/ffmpeg_kit',
      'markcut/pick',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _dir.path,
    );
    b.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  tearDownAll(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('只有批次與 GIF 草稿：草稿分頁列得出來', (t) async {
    _seed(batch: true, gif: true);
    _iphone14(t);
    await _pump(t, const ProfileScreen());

    expect(find.text('還沒有草稿'), findsNothing, reason: '明明有兩份草稿卻說沒有');
    expect(find.text('未完成的批次浮水印'), findsOneWidget);
    expect(find.text('未完成的 GIF'), findsOneWidget);
    // 兩份而已，四格放得下：不該有「查看全部」
    expect(find.text('查看全部'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('草稿比四格多：第四格是「+N 查看全部」，點進去全部都在', (t) async {
    _seed(photo: true, batch: true, gif: true, collage: true, videos: 2);
    _iphone14(t);
    await _pump(t, const ProfileScreen());

    // 六份：影片兩份在前，接著照片、批次……第四格（批次）壓暗、寫「+2
    // 查看全部」——N 是四格之外還有幾份（GIF、拼圖）
    final more = find.byKey(const ValueKey('profile-drafts-more'));
    expect(more, findsOneWidget, reason: '草稿比格子多卻沒有查看全部');
    expect(find.descendant(of: more, matching: find.text('+2')), findsOneWidget);
    expect(
      find.descendant(of: more, matching: find.text('查看全部')),
      findsOneWidget,
    );
    expect(find.text('未完成的照片'), findsOneWidget);
    expect(find.text('未完成的拼圖'), findsNothing, reason: '第五份不該畫在主頁');

    await t.tap(more);
    await _settle(t, 25);
    expect(find.byType(DraftsScreen), findsOneWidget, reason: '點查看全部沒有進草稿夾');
    for (final s in const ['未完成的照片', '未完成的批次浮水印', '未完成的 GIF', '未完成的拼圖']) {
      expect(find.text(s), findsOneWidget, reason: '查看全部少了「$s」');
    }
    // 上面只有返回鍵跟「批次刪除」
    expect(find.text('批次刪除'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('只有拼圖草稿：一樣列得出來', (t) async {
    _seed(collage: true);
    _iphone14(t);
    await _pump(t, const ProfileScreen());
    expect(find.text('還沒有草稿'), findsNothing);
    expect(find.text('未完成的拼圖'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  group('草稿卡點下去直接接續（不是只進資料夾）', () {
    testWidgets('批次浮水印 → 批次頁，帶著整批檔案與草稿', (t) async {
      _seed(batch: true);
      _iphone14(t);
      final spy = _RouteSpy();
      await _pump(t, const ProfileScreen(), spy: spy);
      await t.tap(find.text('未完成的批次浮水印'));
      await _settle(t, 30);

      expect(spy.edits, isNotEmpty, reason: '點卡片沒有開批次頁');
      final page = spy.lastEdit(t);
      expect(page, isA<BatchWatermarkScreen>());
      expect((page as BatchWatermarkScreen).restore, isNotNull, reason: '沒帶草稿');
      expect([for (final f in page.files) f.path], [_p('a.png'), _p('b.png')]);
      expect(find.byType(BatchWatermarkScreen), findsOneWidget);
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('GIF → GIF 製作頁，帶著那支影片與草稿', (t) async {
      _seed(gif: true);
      _iphone14(t);
      final spy = _RouteSpy();
      await _pump(t, const ProfileScreen(), spy: spy);
      await t.tap(find.text('未完成的 GIF'));
      await _settle(t, 30);

      expect(spy.edits, isNotEmpty, reason: '點卡片沒有開 GIF 製作頁');
      final page = spy.lastEdit(t);
      expect(page, isA<GifScreen>());
      expect((page as GifScreen).path, _p('a.mp4'));
      expect(page.restore, isNotNull, reason: '沒帶草稿');
      // 測試環境沒有播放器外掛，製作頁開不了片會自己提示＋退回來
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('拼圖 → 拼圖頁，帶著草稿', (t) async {
      _seed(collage: true);
      _iphone14(t);
      final spy = _RouteSpy();
      await _pump(t, const ProfileScreen(), spy: spy);
      await t.tap(find.text('未完成的拼圖'));
      await _settle(t, 30);

      expect(spy.edits, isNotEmpty, reason: '點卡片沒有開拼圖頁');
      final page = spy.lastEdit(t);
      expect(page, isA<CollageScreen>());
      expect((page as CollageScreen).restore, isNotNull, reason: '沒帶草稿');
      await _drain(t);
      expect(t.takeException(), isNull);
    });

    testWidgets('照片 → 照片編輯頁，帶著那張照片', (t) async {
      _seed(photo: true);
      _iphone14(t);
      final spy = _RouteSpy();
      await _pump(t, const ProfileScreen(), spy: spy);
      await t.tap(find.text('未完成的照片'));
      await _settle(t, 30);

      expect(spy.edits, isNotEmpty, reason: '點卡片沒有開照片編輯頁');
      final page = spy.lastEdit(t);
      expect(page, isA<PhotoEditorScreen>());
      expect((page as PhotoEditorScreen).photo.path, _p('a.png'));
      await _drain(t);
      expect(t.takeException(), isNull);
    });
  });

  for (final kind in ['photo', 'batch', 'collage', 'gif']) {
    testWidgets('$kind 草稿在 App 目錄變動後仍能開啟現有素材', (t) async {
      _seed(
        photo: kind == 'photo',
        batch: kind == 'batch',
        collage: kind == 'collage',
        gif: kind == 'gif',
      );
      AppMediaPaths.setRootForTest(_dir.path);
      addTearDown(() => AppMediaPaths.setRootForTest(null));
      final documents = Directory(
        '${_dir.path}${Platform.pathSeparator}Documents',
      )..createSync();
      for (final name in ['a.png', 'b.png', 'a.mp4']) {
        File(
          _p(name),
        ).copySync('${documents.path}${Platform.pathSeparator}$name');
      }
      final key = '${kind}_draft_v1';
      final prefs = await SharedPreferences.getInstance();
      final original = AppMediaPaths.mapDraft(
        jsonDecode(prefs.getString(key)!) as Map<String, dynamic>,
        transform: (p) =>
            '/private/var/mobile/Containers/Data/Application/OLD/Documents/${p.split(Platform.pathSeparator).last}',
      );
      await prefs.setString(key, jsonEncode(original));
      _iphone14(t);
      final spy = _RouteSpy();
      await _pump(t, const ProfileScreen(), spy: spy);
      final label = switch (kind) {
        'photo' => '未完成的照片',
        'batch' => '未完成的批次浮水印',
        'collage' => '未完成的拼圖',
        _ => '未完成的 GIF',
      };
      await t.tap(find.text(label));
      await _settle(t, 35);
      expect(spy.edits, isNotEmpty);
      final page = spy.lastEdit(t);
      final String restored = switch (page) {
        PhotoEditorScreen() => page.photo.path,
        BatchWatermarkScreen() => page.files.first.path,
        CollageScreen() => (page.restore!['photos'] as List).first as String,
        GifScreen() => page.path,
        _ => throw StateError('Unexpected page ${page.runtimeType}'),
      };
      expect(restored.startsWith(documents.path), isTrue);
      expect(File(restored).existsSync(), isTrue);
      expect(find.textContaining('原草稿已保留'), findsNothing);
      await t.pumpWidget(const SizedBox());
      await _settle(t);
      await _drain(t);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('批次有素材讀不到時不開啟會覆蓋原草稿的殘缺版本', (t) async {
    _seed(batch: true);
    final prefs = await SharedPreferences.getInstance();
    final d =
        jsonDecode(prefs.getString(kBatchDraftKey)!) as Map<String, dynamic>;
    d['files'] = [_p('a.png'), _p('not-here.png')];
    final original = jsonEncode(d);
    await prefs.setString(kBatchDraftKey, original);
    _iphone14(t);
    final spy = _RouteSpy();
    await _pump(t, const ProfileScreen(), spy: spy);
    await t.tap(find.text('未完成的批次浮水印'));
    await _settle(t, 35);
    expect(spy.edits, isEmpty);
    expect(prefs.getString(kBatchDraftKey), original);
    expect(find.textContaining('原草稿已保留'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await _drain(t);
  });

  testWidgets('「我的 GIF」的 ＋ 面板：橫向 667×375 不溢出、最後一列按得到', (t) async {
    SharedPreferences.setMockInitialValues({});
    _landscape(t, 667, 375);
    await _pump(t, const GifsScreen());
    await t.tap(find.byType(FloatingActionButton));
    await _settle(t, 10);
    expect(t.takeException(), isNull, reason: '橫向的面板溢出了');
    expect(find.text('從檔案匯入 GIF'), findsOneWidget);
    // 最後一列可能在畫面外：捲到它露出來為止
    await t.ensureVisible(find.text('從檔案匯入 GIF'));
    await _settle(t, 3);
    final r = t.getRect(find.text('從檔案匯入 GIF'));
    expect(r.bottom, lessThanOrEqualTo(375), reason: '「從檔案匯入 GIF」還在畫面外');
    expect(r.top, greaterThanOrEqualTo(0));
    expect(t.takeException(), isNull);
  });
}
