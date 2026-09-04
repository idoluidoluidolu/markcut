// 「我的 GIF」瀑布流的版面（見 GifsScreen）。
//
// 這一頁的兩欄流從「SingleChildScrollView 包兩個 Column」改成
// 「SliverCrossAxisGroup 包兩條 SliverVariedExtentList」——為的是
// 只做看得到的那幾格（四十個動圖同時解碼是捲不動的），版面本身
// 一格都不能動。這支就是釘住版面：每一格的位置與大小，還有整頁
// 可捲的距離，都要跟舊的算式對得起來。
//
// 舊的算式：
//   SingleChildScrollView(padding 16/16/16/96)
//     → Row[ Expanded(colW), SizedBox(10), Expanded(colW) ]
//     → 每欄 Column[ tile, SizedBox(height: 10), ... ]
//   colW = (畫面寬 - 16*2 - 10) / 2，每格高 = colW ÷ 原始寬高比
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_image.dart';

late String _gifDir;

/// 直式、方形、橫式各一種，瀑布流才排得出高低差
const _sizes = [(240, 320), (280, 280), (320, 240)];

const _screenW = 390.0;
const _colW = (_screenW - 16 * 2 - 10) / 2;

img.Image _frame(int w, int h, int seed) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, x * 255 ~/ w, y * 255 ~/ h, (seed * 37) & 0xFF);
    }
  }
  return im;
}

/// 寫 [n] 個 GIF 進 GifStore 的資料夾；回傳「清單順序」的寬高比
/// （GifStore.list 是照修改時間新到舊）
List<double> _writeGifs(int n) {
  for (final f in Directory(_gifDir).listSync().whereType<File>()) {
    f.deleteSync();
  }
  for (var i = 0; i < n; i++) {
    final (w, h) = _sizes[i % _sizes.length];
    final enc = img.GifEncoder(numColors: 32, samplingFactor: 30);
    enc.addFrame(_frame(w, h, i), duration: 8);
    enc.addFrame(_frame(w, h, i + 9), duration: 8);
    File('$_gifDir${Platform.pathSeparator}gif_$i.gif')
      ..writeAsBytesSync(enc.finish()!)
      ..setLastModifiedSync(DateTime(2026).add(Duration(days: i)));
  }
  return [
    for (var i = n - 1; i >= 0; i--)
      _sizes[i % _sizes.length].$1 / _sizes[i % _sizes.length].$2,
  ];
}

/// 舊版的排法：每一個丟進目前比較短的那一欄。
/// 回傳（每一格的欄號與 y、兩欄各自的總高）
({List<int> col, List<double> y, List<double> colH}) _oldLayout(
  List<double> aspects,
) {
  final col = <int>[];
  final y = <double>[];
  final h = [0.0, 0.0];
  for (final a in aspects) {
    final c = h[0] <= h[1] ? 0 : 1;
    col.add(c);
    y.add(16 + h[c]); // 上方 padding 16
    h[c] += _colW / a + 10; // 一格 ＋ SizedBox(height: 10)
  }
  return (col: col, y: y, colH: h);
}

Future<void> _settle(WidgetTester t, [int n = 60]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// 比例是一個一個非同步量出來的（見 GifsScreen._reload），量到一個
/// 版面就重排一次。等到可捲距離連續 20 次都不動了才算排完
Future<void> _settleLayout(WidgetTester t) async {
  var last = -1.0;
  var same = 0;
  for (var i = 0; i < 400 && same < 20; i++) {
    await _settle(t, 1);
    final now = t
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .maxScrollExtent;
    same = now == last ? same + 1 : 0;
    last = now;
  }
}

Future<void> _pump(WidgetTester t) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      home: const LightPage(child: GifsScreen()),
    ),
  );
  await _settle(t);
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('markcut_gif_grid');
    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(_screenW * 3, 2532);
    v.devicePixelRatio = 3.0;
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    _gifDir = '${dir.path}${Platform.pathSeparator}gifs';
    Directory(_gifDir).createSync(recursive: true);
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('每一格的位置與大小跟舊的兩欄 Column 一模一樣', (t) async {
    // 六個：一頁放得下，全部都做得出來才比得了每一格
    final aspects = _writeGifs(6);
    await _pump(t);
    await _settleLayout(t);

    final tiles = find.byType(GifImage);
    expect(tiles, findsNWidgets(aspects.length));

    final want = _oldLayout(aspects);
    // widget tree 的順序是「第 0 欄由上到下，再第 1 欄」
    final order = [
      for (var i = 0; i < aspects.length; i++)
        if (want.col[i] == 0) i,
      for (var i = 0; i < aspects.length; i++)
        if (want.col[i] == 1) i,
    ];
    // Scaffold 有 AppBar，body 不是從螢幕頂開始：座標都對捲動區的原點
    final origin = t.getRect(find.byType(Scrollable).first).topLeft;
    for (var k = 0; k < order.length; k++) {
      final i = order[k];
      final r = t.getRect(tiles.at(k)).shift(-origin);
      final wantX = want.col[i] == 0 ? 16.0 : 16.0 + _colW + 10;
      expect(
        r.left,
        moreOrLessEquals(wantX, epsilon: 0.01),
        reason: '第 $i 格的 x',
      );
      expect(
        r.top,
        moreOrLessEquals(want.y[i], epsilon: 0.01),
        reason: '第 $i 格的 y',
      );
      expect(
        r.width,
        moreOrLessEquals(_colW, epsilon: 0.01),
        reason: '第 $i 格的寬',
      );
      expect(
        r.height,
        moreOrLessEquals(_colW / aspects[i], epsilon: 0.01),
        reason: '第 $i 格的高',
      );
    }
  });

  testWidgets('看不到的格子不做出來，可捲的距離仍然是準的', (t) async {
    final aspects = _writeGifs(24);
    await _pump(t);
    await _settleLayout(t);

    // 只做看得到的那幾格：動圖不會在畫面外空轉
    final built = find.byType(GifImage).evaluate().length;
    expect(built, lessThan(aspects.length), reason: '整片都做出來了＝二十四個動圖同時在解碼');
    expect(built, greaterThan(2), reason: '看得到的那幾格沒做出來');

    // 可捲距離＝比較高那一欄 ＋ 上 16 ＋ 下 96 － 視窗高。
    // SliverVariedExtentList 拿得到每一格的高度，所以這個數字一開始
    // 就是準的，不是「照已經做出來那幾格的平均去猜」
    final want = _oldLayout(aspects);
    final content =
        (want.colH[0] > want.colH[1] ? want.colH[0] : want.colH[1]) + 16 + 96;
    final pos = t
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(content, greaterThan(pos.viewportDimension), reason: '內容沒有比視窗高');
    expect(
      pos.maxScrollExtent,
      moreOrLessEquals(content - pos.viewportDimension, epsilon: 0.5),
      reason: '可捲距離跟舊版的算式對不上',
    );

    // 捲到底：最後一格要正好停在「內容底部」，不會多一截或少一截
    await t.drag(find.byType(Scrollable).first, const Offset(0, -6000));
    await _settle(t, 20);
    expect(
      pos.pixels,
      moreOrLessEquals(pos.maxScrollExtent, epsilon: 0.5),
      reason: '甩到底之後停的位置不對',
    );
    expect(t.takeException(), isNull);
  });
}
