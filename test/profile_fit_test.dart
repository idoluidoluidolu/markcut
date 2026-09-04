// 個人中心要「一頁就看得完」——不能上下捲（使用者指定
// 「那讓他不要能上下捲動」）。
//
// 版面沒有重新設計：缺的高度先跟可壓縮的留白拿（區塊間距最多兩成、
// 返回鍵下面與行動鈕前面最多一半，合計 33.4pt），剩下的由三排磚用
// 同一個係數一起縮，長寬比與相對比例都不動。縮到 0.75 還是塞不下
//（SE、字級調很大）就回去捲——**截掉東西才是 bug，捲不是**。
//
// 所以這裡量的是兩件事：
//   1. 說「不能捲」的時候，maxScrollExtent 必須是 0。
//      不是 0 就代表有東西被切在畫面外，而且使用者捲不到它。
//   2. 塞不下的時候一定要回到可捲，而不是硬畫、爆版。
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
const _sideH = 44.0;

/// 磚最小縮到 0.75（跟畫面裡的 _kTileFloor 同一個數字）
const _floor = 0.75;

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

ScrollPosition _pos(WidgetTester t) =>
    t.state<ScrollableState>(find.byType(Scrollable).first).position;

bool _locked(WidgetTester t) =>
    t.widget<SingleChildScrollView>(find.byType(SingleChildScrollView)).physics
        is NeverScrollableScrollPhysics;

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

  for (final d in [_iphone14, _proMax]) {
    testWidgets('${d.name}：一頁裝得下，捲不動', (t) async {
      _seed();
      await _pump(t, d);
      expect(t.takeException(), isNull);

      // 有東西可捲＝有東西在畫面外＝被切掉了
      expect(_pos(t).maxScrollExtent, 0, reason: '${d.name} 還有東西在畫面外');
      expect(_locked(t), isTrue, reason: '${d.name} 應該是不能捲的');

      // 三排磚都在
      expect(find.byType(WatermarkLayer), findsNWidgets(2));
      expect(find.byType(GifImage), findsNWidgets(3));
      expect(find.byType(AspectRatio), findsNWidgets(2));

      final inner = d.size.width - _sideH;
      final preset = t.getSize(find.byType(WatermarkLayer).first);
      final gif = t.getSize(find.byType(GifImage).first);
      final draft = t.getSize(find.byType(AspectRatio).first);

      // 長寬比不准跑掉：兩排正方、草稿 3:4
      expect(preset.width, closeTo(preset.height, 0.01));
      expect(gif.width, closeTo(gif.height, 0.01));
      expect(draft.width / draft.height, closeTo(3 / 4, 0.001));

      // 三排共用同一個縮放係數，相對比例才不會散掉
      final sp = preset.width / ((inner - 10) / 2);
      final sg = gif.width / ((inner - 20) / 3);
      final sd = draft.width / ((inner - 12) / 2);
      expect(sg, closeTo(sp, 0.001), reason: 'GIF 那排的縮放跟範本不一樣');
      expect(sd, closeTo(sp, 0.001), reason: '草稿那排的縮放跟範本不一樣');
      expect(sp, lessThanOrEqualTo(1.0));
      expect(sp, greaterThanOrEqualTo(_floor));

      // 縮小之後左右要一樣寬，不然整排會黏在左邊
      final row = t.getRect(find.byType(GifImage).last);
      expect(
        d.size.width - row.right,
        closeTo(t.getRect(find.byType(GifImage).first).left, 0.01),
        reason: 'GIF 那排沒有置中',
      );

      // ignore: avoid_print
      print(
        '[fit] ${d.name}  縮放 ${sp.toStringAsFixed(3)}  '
        '範本 ${preset.width.toStringAsFixed(1)}  '
        'GIF ${gif.width.toStringAsFixed(1)}  '
        '草稿 ${draft.width.toStringAsFixed(1)}×'
        '${draft.height.toStringAsFixed(1)}',
      );
    });
  }

  testWidgets('${_se.name}：塞不下就回去捲，不是把東西截掉', (t) async {
    _seed();
    await _pump(t, _se);
    expect(t.takeException(), isNull);
    expect(_locked(t), isFalse, reason: 'SE 應該退回可捲');
    expect(_pos(t).maxScrollExtent, greaterThan(0));

    // 退回可捲＝完全照原本的尺寸畫，一格都不縮
    final inner = _se.size.width - _sideH;
    expect(
      t.getSize(find.byType(WatermarkLayer).first).width,
      closeTo((inner - 10) / 2, 0.01),
    );
    expect(
      t.getSize(find.byType(GifImage).first).width,
      closeTo((inner - 20) / 3, 0.01),
    );

    // 捲到底也還是好好的（沒有爆版）
    await t.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
    await t.pump();
    expect(t.takeException(), isNull);
  });

  // 字級調大 → 三個標題與頁尾一起長高 → 磚要讓出更多。
  // 1.6 還撐得住（磚縮到 0.77，仍在 0.75 的底線上），2.0 就撐不住了，
  // 這時**一定**要退回可捲：硬畫就是紅黃斜紋，或是字被切掉
  for (final scale in [1.6, 2.0]) {
    testWidgets('字級 $scale：不硬擠、也不爆版', (t) async {
      _seed();
      await _pump(t, _iphone14, textScale: scale);
      expect(t.takeException(), isNull, reason: '字級 $scale 爆版了');
      if (_locked(t)) {
        expect(_pos(t).maxScrollExtent, 0, reason: '鎖住了卻還有東西在畫面外');
      } else {
        expect(_pos(t).maxScrollExtent, greaterThan(0));
      }
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

    // 內容少、本來就裝得下 → 縮放要卡在 1.0，跟以前逐點一樣
    final inner = _iphone14.size.width - _sideH;
    expect(t.getSize(find.byType(Padding).at(0)).width, _iphone14.size.width);
    expect(
      t.getSize(find.text('＋')).height,
      greaterThan(0),
      reason: '空的時候是一塊「＋」磚',
    );
    final addTile = t.getSize(
      find.ancestor(of: find.text('＋'), matching: find.byType(Container)).first,
    );
    expect(addTile.width, closeTo((inner - 10) / 2, 0.01));
    expect(addTile.height, closeTo((inner - 10) / 2, 0.01));
  });

  testWidgets('草稿只有一張時還是靠左，不會自己跑到中間', (t) async {
    _seed(drafts: 1);
    await _pump(t, _iphone14);
    expect(t.takeException(), isNull);
    expect(find.byType(AspectRatio), findsOneWidget);

    // 縮小是靠左右補一樣寬的邊做的，不是把 Row 置中——只有一張卡的
    // 時候它必須還在整排的左邊，不能自己跑到畫面中間
    final inner = _iphone14.size.width - _sideH;
    final card = t.getRect(find.byType(AspectRatio).first);
    final scale = card.width / ((inner - 12) / 2);
    final gutter = (1 - scale) * (inner - 12) / 2;
    expect(card.left, closeTo(22 + gutter, 0.01), reason: '草稿卡沒有靠左');
    expect(card.left, lessThan(_iphone14.size.width / 4), reason: '草稿卡跑到中間了');
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
  // 而那就是內容被切掉又捲不到。掃一輪各種尺寸把它釘住
  testWidgets('掃各種尺寸：只要鎖住不給捲，就一定是 0 可捲距離', (t) async {
    for (final w in [360.0, 390.0, 430.0]) {
      for (var h = 640.0; h <= 940.0; h += 20) {
        for (final content in [(2, 3, 2), (1, 0, 1), (0, 0, 0), (2, 2, 2)]) {
          _seed(presets: content.$1, gifs: content.$2, drafts: content.$3);
          await _pump(t, (
            name: '${w}x$h',
            size: Size(w, h),
            top: 47.0,
            bottom: 34.0,
          ));
          expect(t.takeException(), isNull, reason: '$w×$h $content 爆版了');
          if (_locked(t)) {
            expect(
              _pos(t).maxScrollExtent,
              0,
              reason: '$w×$h $content 鎖住了卻還有東西在畫面外',
            );
          }
        }
      }
    }
  });
}
