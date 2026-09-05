// 個人中心要「一頁就看得完」——不能上下捲（使用者指定
// 「那讓他不要能上下捲動」）。
//
// D 案之後磚不再縮：三排磚永遠原尺寸、滿版寬（實機回報「左右 PADDING
// 很大」——以前磚縮小後兩邊各補 20 幾 pt 的邊）。缺的高度只跟可壓縮的
// 留白拿（區塊間距最多兩成、返回鍵下面與行動鈕前面最多一半，合計
// 33.4pt），壓到底還是塞不下（SE、字級調很大）就回去捲——
// **截掉東西才是 bug，捲不是**。
//
// 所以這裡量的是三件事：
//   1. 說「不能捲」的時候，maxScrollExtent 必須是 0。
//      不是 0 就代表有東西被切在畫面外，而且使用者捲不到它。
//   2. 塞不下的時候一定要回到可捲，而不是硬畫、爆版。
//   3. 不管捲不捲，磚都是原尺寸、貼著 22pt 的左右留白——沒有補邊。
//
// 安全區一定要給真的數字（瀏海 47＋home 條 34）：沒有安全區的測試
// 少算了將近 100pt，量到的綠燈是假的。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_image.dart';
import 'package:markcut/widgets/watermark_layer.dart';

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

/// 左右留白（跟畫面裡的 _side 同一個數字）
const _side = 22.0;

/// 三格一排的格寬：GIF 跟範本同一種格子（跟畫面裡的 cell 同一條公式）
double _cell(double width) => (width - _side * 2 - 20) / 3;

/// 草稿卡的寬（兩欄、中間 12）
double _draftW(double width) => (width - _side * 2 - 12) / 2;

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
      // 每次都換一把 key：同一支測試連續 pump 好幾組資料時，樹長得
      // 一樣 State 就會被沿用，_reload 不會再跑，畫面還是上一組的
      // 東西（以前的掃描只量可捲距離，沒被這個咬到）
      home: LightPage(child: ProfileScreen(key: UniqueKey())),
    ),
  );
  await _settle(t);
}

ScrollPosition _pos(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable).first).position;

bool _locked(WidgetTester t) =>
    t.widget<SingleChildScrollView>(find.byType(SingleChildScrollView)).physics
        is NeverScrollableScrollPhysics;

/// 「＋ 新增範本」那塊磚（邊線算在磚裡）
Finder get _addTile =>
    find.ancestor(of: find.text('＋'), matching: find.byType(Container)).first;

/// 磚永遠原尺寸、貼著左右留白：這是 D 案的合約，鎖住或捲都一樣。
/// 磚的數量照 [presets]/[gifs]/[drafts] 給（範本不足三組會補「＋」）
void _expectRowsUnscaled(
  WidgetTester t,
  Device d, {
  int presets = 2,
  int gifs = 3,
  int drafts = 2,
}) {
  final w = d.size.width;
  final cell = _cell(w);

  // 範本：磚是正方、第一塊貼左；不足三組時「＋」補在下一格
  expect(find.byType(WatermarkLayer), findsNWidgets(presets.clamp(0, 3)));
  if (presets > 0) {
    final first = t.getRect(find.byType(WatermarkLayer).first);
    expect(first.width, closeTo(cell, 0.01), reason: '${d.name} 範本磚寬不對');
    expect(first.height, closeTo(cell, 0.01), reason: '${d.name} 範本磚不是正方');
    expect(first.left, closeTo(_side, 0.01), reason: '${d.name} 範本那排沒貼左');
  }
  if (presets < 3) {
    final add = t.getRect(_addTile);
    expect(add.width, closeTo(cell, 0.01), reason: '${d.name} ＋磚寬不對');
    expect(add.height, closeTo(cell, 0.01));
    expect(
      add.left,
      closeTo(_side + presets * (cell + 10), 0.01),
      reason: '${d.name} ＋磚沒有接在第 ${presets + 1} 格',
    );
  } else {
    expect(find.text('＋'), findsNothing, reason: '三組範本就不該再有＋磚');
  }

  // GIF：三格一排，第一塊貼左、第三塊貼右
  expect(find.byType(GifImage), findsNWidgets(gifs.clamp(0, 3)));
  if (gifs > 0) {
    final first = t.getRect(find.byType(GifImage).first);
    expect(first.width, closeTo(cell, 0.01), reason: '${d.name} GIF 磚寬不對');
    expect(first.height, closeTo(cell, 0.01));
    expect(first.left, closeTo(_side, 0.01), reason: '${d.name} GIF 那排沒貼左');
    if (gifs >= 3) {
      expect(
        w - t.getRect(find.byType(GifImage).at(2)).right,
        closeTo(_side, 0.01),
        reason: '${d.name} GIF 那排右邊有補邊',
      );
    }
  }

  // 草稿：兩欄 3:4，第一張貼左
  expect(find.byType(AspectRatio), findsNWidgets(drafts.clamp(0, 2)));
  if (drafts > 0) {
    final card = t.getRect(find.byType(AspectRatio).first);
    expect(card.width, closeTo(_draftW(w), 0.01), reason: '${d.name} 草稿卡寬不對');
    expect(card.width / card.height, closeTo(3 / 4, 0.001));
    expect(card.left, closeTo(_side, 0.01), reason: '${d.name} 草稿卡沒貼左');
    if (drafts >= 2) {
      expect(
        w - t.getRect(find.byType(AspectRatio).at(1)).right,
        closeTo(_side, 0.01),
        reason: '${d.name} 草稿那排右邊有補邊',
      );
    }
  }
}

/// 鎖住就一定是 0 可捲距離；沒鎖就一定有東西要捲（不然鎖什麼）
void _expectScrollContract(WidgetTester t, String name) {
  if (_locked(t)) {
    expect(_pos(t).maxScrollExtent, 0, reason: '$name 鎖住了卻還有東西在畫面外');
  } else {
    expect(_pos(t).maxScrollExtent, greaterThan(0), reason: '$name 沒鎖卻沒東西可捲');
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

  // 返回鍵那顆按鈕的高度是算版面用的固定值（profile_screen 的
  // _kNavButton＝48）。它一變，整頁的高度計算就全錯，而錯的方向是
  // 「以為裝得下」——底下的頁尾連結會被切掉且捲不到
  testWidgets('返回鍵的高度還是 48（版面計算的固定值）', (t) async {
    _seed();
    await _pump(t, _iphone14);
    expect(t.getSize(find.byType(IconButton)).height, 48);
  });

  // D 案的順序：草稿→我的 GIF→範本（最常回來找的放最上面）
  testWidgets('區塊順序是草稿→我的 GIF→範本', (t) async {
    _seed();
    await _pump(t, _iphone14);
    final drafts = t.getTopLeft(find.text('草稿')).dy;
    final gifs = t.getTopLeft(find.text('我的 GIF')).dy;
    final presets = t.getTopLeft(find.text('範本')).dy;
    expect(drafts, lessThan(gifs), reason: '草稿要在我的 GIF 上面');
    expect(gifs, lessThan(presets), reason: '我的 GIF 要在範本上面');
  });

  // 範本一排三格：三組就三塊磚、沒有＋；兩組＋一塊＋；一組＋一塊＋
  for (final n in [3, 2, 1]) {
    testWidgets('$n 組範本：一排三格，不足才補＋', (t) async {
      _seed(presets: n);
      await _pump(t, _iphone14);
      expect(t.takeException(), isNull);
      _expectRowsUnscaled(t, _iphone14, presets: n);
    });
  }

  // 三台裝置、東西都滿（兩組範本＋＋磚、三個 GIF、兩份草稿）。
  // 磚不縮，所以裝不裝得下全看留白讓不讓得出來：
  //   Pro Max 讓得出來、鎖住；SE 讓不出來、退回可捲。
  //   iPhone 14 實量：三排磚 440.0pt、固定部分 431.6pt（底墊那 12pt
  //   拿掉之後，使用者指定貼底），差 27.6pt，留白額度 33.4pt 讓得出來
  //   → 鎖住。要是哪天又多塞東西進固定部分，這裡會先紅
  for (final (d, locked) in [
    (_iphone14, true),
    (_proMax, true),
    (_se, false),
  ]) {
    testWidgets('${d.name}：磚原尺寸滿版；鎖住＝0 可捲、塞不下＝可捲', (t) async {
      _seed();
      await _pump(t, d);
      expect(t.takeException(), isNull);
      _expectScrollContract(t, d.name);
      _expectRowsUnscaled(t, d);
      expect(
        _locked(t),
        locked,
        reason: locked ? '${d.name} 應該裝得下、不能捲' : '${d.name} 應該退回可捲',
      );

      // 捲到底也還是好好的（沒有爆版）；鎖住的話拖了也不會動
      await t.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
      await t.pump();
      expect(t.takeException(), isNull);
      if (_locked(t)) expect(_pos(t).pixels, 0);

      final cell = _cell(d.size.width);
      final draft = t.getSize(find.byType(AspectRatio).first);
      // ignore: avoid_print
      print(
        '[fit] ${d.name}  ${_locked(t) ? '鎖住' : '可捲 ${_pos(t).maxScrollExtent.toStringAsFixed(1)}pt'}  '
        '格 ${cell.toStringAsFixed(1)}  '
        '草稿 ${draft.width.toStringAsFixed(1)}×'
        '${draft.height.toStringAsFixed(1)}',
      );
    });
  }

  // 字級調大 → 三個標題與頁尾一起長高 → 留白讓不出那麼多。
  // 磚不縮，所以撐不住就**一定**要退回可捲：硬畫就是紅黃斜紋，
  // 或是字被切掉
  for (final scale in [1.6, 2.0]) {
    testWidgets('字級 $scale：不硬擠、也不爆版', (t) async {
      _seed();
      await _pump(t, _iphone14, textScale: scale);
      expect(t.takeException(), isNull, reason: '字級 $scale 爆版了');
      _expectScrollContract(t, '字級 $scale');
      _expectRowsUnscaled(t, _iphone14);
      if (scale == 2.0) {
        expect(_locked(t), isFalse, reason: '字級 2.0 應該退回可捲');
      }
    });
  }

  testWidgets('東西少的時候維持原尺寸（空狀態跟以前一模一樣）', (t) async {
    _seed(presets: 0, gifs: 0, drafts: 0);
    await _pump(t, _iphone14);
    expect(t.takeException(), isNull);
    expect(find.text('還沒有 GIF'), findsOneWidget);
    expect(find.text('還沒有草稿'), findsOneWidget);
    expect(_pos(t).maxScrollExtent, 0);
    expect(_locked(t), isTrue);

    // 內容少、本來就裝得下 → 只有一塊「＋」磚，三格一排的第一格
    expect(t.getSize(find.byType(Padding).at(0)).width, _iphone14.size.width);
    expect(
      t.getSize(find.text('＋')).height,
      greaterThan(0),
      reason: '空的時候是一塊「＋」磚',
    );
    _expectRowsUnscaled(t, _iphone14, presets: 0, gifs: 0, drafts: 0);
  });

  testWidgets('草稿只有一張時還是靠左，不會自己跑到中間', (t) async {
    _seed(drafts: 1);
    await _pump(t, _iphone14);
    expect(t.takeException(), isNull);
    expect(find.byType(AspectRatio), findsOneWidget);

    // 沒有補邊、Row 也不置中——只有一張卡的時候它必須還在整排的
    // 左邊，不能自己跑到畫面中間
    final card = t.getRect(find.byType(AspectRatio).first);
    expect(card.left, closeTo(_side, 0.01), reason: '草稿卡沒有靠左');
    expect(card.width, closeTo(_draftW(_iphone14.size.width), 0.01));
  });

  testWidgets('轉成橫的：高度只剩 390，一定要退回可捲', (t) async {
    _seed();
    await _pump(t, (
      name: '橫的',
      size: const Size(844, 390),
      top: 0.0,
      bottom: 21.0,
    ));
    expect(t.takeException(), isNull);
    expect(_locked(t), isFalse);
  });

  // 說「不能捲」就一定要真的裝得下：高度計算是自己算出來的
  // （文字用 TextPainter 實量），算錯的方向永遠是「以為裝得下」，
  // 而那就是內容被切掉又捲不到。掃一輪各種尺寸把它釘住；
  // 順便釘住「磚永遠原尺寸」——不管鎖住還是捲
  testWidgets('掃各種尺寸：只要鎖住不給捲，就一定是 0 可捲距離', (t) async {
    for (final w in [360.0, 390.0, 430.0]) {
      for (var h = 640.0; h <= 940.0; h += 20) {
        for (final content in [(2, 3, 2), (1, 0, 1), (0, 0, 0), (2, 2, 2)]) {
          _seed(presets: content.$1, gifs: content.$2, drafts: content.$3);
          final d = (
            name: '${w}x$h',
            size: Size(w, h),
            top: 47.0,
            bottom: 34.0,
          );
          await _pump(t, d);
          expect(t.takeException(), isNull, reason: '$w×$h $content 爆版了');
          _expectScrollContract(t, '$w×$h $content');
          _expectRowsUnscaled(
            t,
            d,
            presets: content.$1,
            gifs: content.$2,
            drafts: content.$3,
          );
        }
      }
    }
  });
}
