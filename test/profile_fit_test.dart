// 個人中心（C 案，使用者定案）：三個分頁（草稿／GIF／範本），選中的
// 標題 30、其他 20。草稿兩欄 3:4 最多四格，比格子多的時候第四格是
// 「+N 查看全部」；GIF 與範本分頁是原本「我的 GIF」、範本夾那一套兩欄
// 瀑布流（使用者指定），全部列出來，右下角一顆＋。
//
// 版面的合約：
//   1. 格子永遠原尺寸、貼著 22pt 的左右留白——沒有補邊、不置中。
//   2. 裝得下就不能捲（maxScrollExtent 是 0，使用者指定「不要能上下
//      捲動」），頁尾貼著底部；裝不下（東西多、橫向、字級調很大）就一定
//      捲得到頁尾——**截掉東西才是 bug，捲不是**。
//
// 安全區一定要給真的數字（瀏海 47＋home 條 34）：沒有安全區的測試
// 少算了將近 100pt，量到的綠燈是假的。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/presets_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/screens/storage_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_image.dart';

/// 一台裝置：邏輯尺寸＋安全區
typedef Device = ({String name, Size size, double top, double bottom});

const _iphone14 = (
  name: 'iPhone 14',
  size: Size(390, 844),
  top: 47.0,
  bottom: 34.0,
);
const _proMax = (
  name: 'iPhone Pro Max',
  size: Size(430, 932),
  top: 59.0,
  bottom: 34.0,
);
const _se = (name: 'iPhone SE', size: Size(375, 667), top: 20.0, bottom: 0.0);
const _landscape = (
  name: '橫的',
  size: Size(844, 390),
  top: 0.0,
  bottom: 21.0,
);

/// 左右留白（跟畫面裡的 _side 同一個數字）
const _side = 22.0;

/// GIF 與範本：兩欄瀑布流的欄寬（欄距 10）
double _colW(double width) => (width - _side * 2 - 10) / 2;

/// 草稿：兩欄 3:4、格距 10
double _draftW(double width) => (width - _side * 2 - 10) / 2;

late final String _tmp;

/// 最小的合法 GIF（1×1 透明）
const _gifBytes = <int>[
  71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, //
  255, 255, 255, 33, 249, 4, 1, 10, 0, 1, 0, 44, 0, 0, 0, 0, //
  1, 0, 1, 0, 0, 2, 2, 76, 1, 0, 59,
];

/// SharedPreferences 與 GifStore 都是真的非同步：只 pump 一次的話
/// _reload 的 setState 還沒回來，畫面還是空的（量到的就是空狀態，
/// 那是假綠燈）
Future<void> _settle(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

WatermarkPreset _preset(int i) => WatermarkPreset(
  name: '範本 $i',
  settings: WatermarkSettings()..text.text = '@我的浮水印 $i',
);

/// 種資料：範本存在 prefs、GIF 是文件目錄底下真的檔案、
/// 影片草稿是 project_data_* 的內容鍵（索引會自己重建）
void _seed({int presets = 2, int gifs = 3, int drafts = 2}) {
  final data = <String, Object>{'wm_presets_seeded_v1': true};
  if (presets > 0) {
    data['wm_presets_v1'] = <String>[
      for (var i = 0; i < presets; i++) _preset(i).encode(),
    ];
  }
  for (var i = 0; i < drafts; i++) {
    data['project_data_p$i'] = jsonEncode({
      'savedAt': DateTime(2026, 8, 20 - i).toIso8601String(),
      'clips': [
        {'id': 1},
      ],
    });
  }
  SharedPreferences.setMockInitialValues(data);

  final dir = Directory('$_tmp${Platform.pathSeparator}gifs');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  for (var i = 0; i < gifs; i++) {
    File(
      '${dir.path}${Platform.pathSeparator}gif_$i.gif',
    ).writeAsBytesSync(_gifBytes);
  }
}

Future<void> _pump(WidgetTester t, Device d, {double textScale = 1.0}) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = d.size;
  t.view.padding = FakeViewPadding(top: d.top, bottom: d.bottom);
  t.view.viewPadding = FakeViewPadding(top: d.top, bottom: d.bottom);
  t.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  await t.pumpWidget(
    MaterialApp(
      // App 的預設佈景是深色；淺色是在 route 層包上去的，
      // 測試也照同一種方式包，不然量到的不是真的長相
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      home: const LightPage(child: ProfileScreen()),
    ),
  );
  await _settle(t);
}

Future<void> _openTab(WidgetTester t, int i) async {
  await t.tap(find.byKey(ValueKey('profile-tab-$i')));
  await _settle(t, 6);
}

ScrollPosition _pos(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable).first).position;

double? _tabSize(WidgetTester t, int i) => t
    .widget<AnimatedDefaultTextStyle>(
      find.descendant(
        of: find.byKey(ValueKey('profile-tab-$i')),
        matching: find.byType(AnimatedDefaultTextStyle),
      ),
    )
    .style
    .fontSize;

/// 「+N 查看全部」那一格
void _expectMore(WidgetTester t, String key, int? n) {
  final more = find.byKey(ValueKey(key));
  if (n == null) {
    expect(more, findsNothing, reason: '格子放得下卻有查看全部');
    return;
  }
  expect(more, findsOneWidget, reason: '東西比格子多卻沒有查看全部');
  expect(find.descendant(of: more, matching: find.text('+$n')), findsOneWidget);
  expect(
    find.descendant(of: more, matching: find.text('查看全部')),
    findsOneWidget,
  );
}

/// 兩欄瀑布流：每一格都是一欄寬，貼著左右留白排成兩欄
void _expectMasonry(WidgetTester t, Finder tiles, double width) {
  final colW = _colW(width);
  final n = tiles.evaluate().length;
  for (var i = 0; i < n; i++) {
    final r = t.getRect(tiles.at(i));
    expect(r.width, closeTo(colW, 0.01), reason: '第 $i 格不是一欄寬');
    expect(
      r.left,
      anyOf(closeTo(_side, 0.01), closeTo(_side + colW + 10, 0.01)),
      reason: '第 $i 格不在兩欄的位置上',
    );
  }
}

/// 裝得下＝0 可捲、頁尾貼底；裝不下＝捲到底看得到整個頁尾
Future<void> _expectFooterReachable(WidgetTester t, Device d) async {
  final pos = _pos(t);
  final max = pos.maxScrollExtent;
  if (max > 0) {
    pos.jumpTo(max);
    await t.pump();
  }
  final foot = t.getRect(find.text('關於這個 App'));
  expect(
    foot.bottom,
    lessThanOrEqualTo(d.size.height - d.bottom + 0.01),
    reason: '${d.name} 頁尾被切掉、捲不到',
  );
  if (max == 0) {
    // 頁尾貼底（底部安全區上面留 10）
    expect(
      foot.bottom,
      closeTo(d.size.height - d.bottom - 10, 1),
      reason: '${d.name} 頁尾沒有貼著底部',
    );
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final (family, path) in const [
      ('NotoSansTC', 'assets/fonts/NotoSansTC.ttf'),
      ('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
    _tmp = Directory.systemTemp.createTempSync('markcut_profile_fit').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => _tmp,
        );
  });

  testWidgets('分頁左到右是草稿→GIF→範本；選中的 30、其他 20', (t) async {
    _seed();
    await _pump(t, _iphone14);
    final x = [
      for (final s in const ['草稿', 'GIF', '範本']) t.getRect(find.text(s)).left,
    ];
    expect(x[0], lessThan(x[1]));
    expect(x[1], lessThan(x[2]));
    expect(x[0], closeTo(_side, 0.01), reason: '分頁標題沒貼著左邊留白');
    expect([_tabSize(t, 0), _tabSize(t, 1), _tabSize(t, 2)], [30, 20, 20]);

    await _openTab(t, 1);
    expect([_tabSize(t, 0), _tabSize(t, 1), _tabSize(t, 2)], [20, 30, 20]);
    await _openTab(t, 2);
    expect([_tabSize(t, 0), _tabSize(t, 1), _tabSize(t, 2)], [20, 20, 30]);
    expect(t.takeException(), isNull);
  });

  // 草稿：兩欄 3:4，最多四格；多的話第四格「+N 查看全部」
  for (final n in [1, 2, 4, 5, 9]) {
    testWidgets('$n 份草稿：兩欄 3:4、最多四格', (t) async {
      _seed(drafts: n);
      await _pump(t, _iphone14);
      expect(t.takeException(), isNull);
      final w = _iphone14.size.width;
      final cw = _draftW(w);
      final tiles = find.byType(AspectRatio);
      final shown = math.min(n, 4);
      expect(tiles, findsNWidgets(shown));
      for (var i = 0; i < shown; i++) {
        final r = t.getRect(tiles.at(i));
        expect(r.width, closeTo(cw, 0.01), reason: '第 $i 格寬不對');
        expect(r.width / r.height, closeTo(3 / 4, 0.001));
        expect(
          r.left,
          closeTo(i.isEven ? _side : _side + cw + 10, 0.01),
          reason: '第 $i 格的位置不對（只有一張也要靠左）',
        );
      }
      _expectMore(t, 'profile-drafts-more', n > 4 ? n - 4 : null);
    });
  }

  testWidgets('沒有草稿：一行「還沒有草稿」', (t) async {
    _seed(drafts: 0);
    await _pump(t, _iphone14);
    expect(find.text('還沒有草稿'), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
    expect(t.takeException(), isNull);
  });

  // GIF：原本「我的 GIF」那一套兩欄瀑布流，全部列出來；右下角一顆＋
  for (final n in [0, 1, 3, 7]) {
    testWidgets('$n 個 GIF：兩欄瀑布流、全部列出來、右下角＋', (t) async {
      _seed(gifs: n);
      await _pump(t, _iphone14);
      await _openTab(t, 1);
      expect(t.takeException(), isNull);
      final gifs = find.byType(GifImage);
      expect(gifs, findsNWidgets(n), reason: 'GIF 分頁沒有全部列出來');
      _expectMasonry(t, gifs, _iphone14.size.width);
      expect(find.text('還沒有 GIF'), n == 0 ? findsOneWidget : findsNothing);
      expect(
        find.byKey(const ValueKey('profile-gif-add')),
        findsOneWidget,
        reason: '右下角少了＋',
      );
      expect(find.text('查看全部'), findsNothing);
    });
  }

  // 範本：跟範本夾一模一樣的兩欄瀑布流（卡片照各自的設計比例）；右下角＋
  for (final n in [0, 2, 5]) {
    testWidgets('$n 組範本：跟範本夾一樣的兩欄瀑布流、右下角＋', (t) async {
      _seed(presets: n);
      await _pump(t, _iphone14);
      await _openTab(t, 2);
      expect(t.takeException(), isNull);
      final cards = find.byType(PresetCard);
      expect(cards, findsNWidgets(n), reason: '範本分頁沒有全部列出來');
      _expectMasonry(t, cards, _iphone14.size.width);
      for (var i = 0; i < n; i++) {
        final r = t.getRect(cards.at(i));
        expect(
          r.width / r.height,
          closeTo(_preset(i).settings.designAspect, 0.01),
          reason: '第 $i 張卡沒照設計比例',
        );
      }
      expect(
        find.text('新增範本'),
        n == 0 ? findsOneWidget : findsNothing,
        reason: '一組都沒有的時候要有入口卡',
      );
      expect(
        find.byKey(const ValueKey('profile-preset-add')),
        findsOneWidget,
        reason: '右下角少了＋',
      );
      expect(find.text('查看全部'), findsNothing);
    });
  }

  testWidgets('草稿分頁沒有＋', (t) async {
    _seed();
    await _pump(t, _iphone14);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  // 東西都滿：草稿分頁（四格＋查看全部）直的手機一頁裝得下，不能捲、
  // 頁尾貼底；GIF 與範本分頁整片列出來，多了就捲，捲到底看得到頁尾
  for (final d in [_iphone14, _proMax, _se]) {
    testWidgets('${d.name}：草稿滿四格也一頁裝得下、頁尾貼底', (t) async {
      _seed(drafts: 9, gifs: 7, presets: 5);
      await _pump(t, d);
      expect(t.takeException(), isNull);
      expect(_pos(t).maxScrollExtent, 0, reason: '${d.name} 一頁裝不下了');
      await _expectFooterReachable(t, d);
      // 裝得下就拖不動（不回彈、不位移）
      await t.drag(find.byType(Scrollable).first, const Offset(0, -300));
      await t.pump();
      expect(_pos(t).pixels, 0);
      for (final tab in [1, 2]) {
        // 捲回頂端：分頁標題捲出畫面就不會被做出來
        _pos(t).jumpTo(0);
        await t.pump();
        await _openTab(t, tab);
        await _expectFooterReachable(t, d);
      }
      expect(t.takeException(), isNull);
    });
  }

  // 裝不下就退回可捲，而且捲得到頁尾：橫向、字級調很大
  for (final (d, scale) in [
    (_landscape, 1.0),
    (_iphone14, 1.6),
    (_iphone14, 2.0),
    (_se, 2.0),
  ]) {
    testWidgets('${d.name} 字級 $scale：不爆版、頁尾一定看得到', (t) async {
      _seed(drafts: 9, gifs: 7, presets: 5);
      await _pump(t, d, textScale: scale);
      expect(t.takeException(), isNull, reason: '${d.name} 字級 $scale 爆版了');
      await _expectFooterReachable(t, d);
      for (final tab in [1, 2]) {
        // 捲回頂端：分頁標題捲出畫面就不會被做出來
        _pos(t).jumpTo(0);
        await t.pump();
        await _openTab(t, tab);
        expect(t.takeException(), isNull);
        await _expectFooterReachable(t, d);
      }
    });
  }

  testWidgets('長按 GIF 磚：背景壓暗、旁邊小選單，選刪除就刪', (t) async {
    _seed(gifs: 2);
    await _pump(t, _iphone14);
    await _openTab(t, 1);
    expect(find.byType(GifImage), findsNWidgets(2));
    await t.longPress(find.byType(GifImage).first);
    await t.pumpAndSettle();
    expect(find.text('刪除這個 GIF？'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing, reason: '跳的是整頁的確認對話框');
    final scrim = t.widget<ModalBarrier>(find.byType(ModalBarrier).last);
    expect(scrim.color, Colors.black.withValues(alpha: 0.5));

    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(find.byType(GifImage), findsNWidgets(2));

    await t.longPress(find.byType(GifImage).first);
    await t.pumpAndSettle();
    await t.tap(find.text('刪除'));
    await _settle(t);
    expect(find.byType(GifImage), findsOneWidget, reason: '選了刪除卻沒刪');
    expect(t.takeException(), isNull);
  });

  testWidgets('點 GIF 放大看；右下角＋開製作／匯入；右上進容量與清理', (t) async {
    _seed(gifs: 3);
    await _pump(t, _iphone14);
    await _openTab(t, 1);
    await t.tap(find.byType(GifImage).first);
    await _settle(t, 10);
    expect(find.byType(PageView), findsOneWidget, reason: '點 GIF 沒有放大看');
    await t.tap(find.byType(PageView)); // 點一下關掉
    await _settle(t, 10);
    expect(find.byType(PageView), findsNothing);

    await t.tap(find.byKey(const ValueKey('profile-gif-add')));
    await _settle(t, 10);
    expect(find.text('從檔案匯入 GIF'), findsOneWidget, reason: '＋沒有開出製作／匯入');
    Navigator.of(t.element(find.text('從檔案匯入 GIF'))).pop();
    await _settle(t, 10);

    await t.tap(find.byKey(const ValueKey('profile-storage')));
    await _settle(t, 20);
    expect(find.byType(StorageScreen), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
