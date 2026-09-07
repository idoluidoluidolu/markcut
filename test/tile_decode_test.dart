// 個人中心、草稿夾、GIF 夾的磚：解碼尺寸、lazy、形狀。
//
//   1. 草稿封面是長邊 720 的 PNG，一張解開就是 405×720×4 ≈ 1.2MB，而卡片
//      實際只畫約 180 邏輯點寬。Image.memory 沒給 cacheWidth 的話每一張
//      都以原尺寸常駐（實機曾有 113 份 ≈ 130MB）。封面一律照磚的尺寸
//      解碼：草稿夾的磚就是封面的比例，欄寬 × dpr 剛好；個人中心的卡
//      是 3:4、封面 cover 進去，直片貼寬、橫片貼高（寬＝高×比例）。
//   2. 草稿夾以前把全部封面一次建出來（ListView 裡唯一一個子項是兩欄
//      Column），三十份就是三十張 Image 同時活著；改成跟「我的 GIF」
//      同一套 SliverVariedExtentList，只做看得到的那幾格。
//   3. GIF 磚同理：匯入的 GIF 尺寸不限（可 1080 寬），每一格都全解析度
//      解碼再縮到一百多點。GIF 夾的磚＝欄寬 × dpr；個人中心的方磚
//      cover 進去，橫的要貼高（寬＝格寬×比例）。
//   4. 同一頁上的磚要同一種角：超橢圓（連續曲率）。以前範本磚是超橢圓、
//      旁邊的 GIF 磚與草稿卡是普通圓弧，擺在一起看得出是兩種角。
//   5. 空狀態那行灰字用 kLTextDim：以前的 #A8A8B4 在白底上對比只有 2.3:1
//   6. 草稿夾的列表卡：InkWell 上面要有自己的 Material，水波才畫得出來
//      （以前 InkWell 直接放在有底色的 Container 裡，水波畫在底色下面）
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/photo_editor_screen.dart' show kPhotoDraftKey;
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_image.dart';

/// 8×8 PNG（封面內容不重要，量的是解碼尺寸）
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
    'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=';

/// 直式、方形、橫式各一種
const _gifSizes = [(240, 320), (280, 280), (320, 240)];

const _w = 390.0;
const _dpr = 3.0;

late Directory _docs;
late Directory _gifDir;

img.Image _frame(int w, int h, int seed) {
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, x * 255 ~/ w, y * 255 ~/ h, (seed * 37) & 0xFF);
    }
  }
  return im;
}

/// 寫 [n] 個真的 GIF（兩格）進 GifStore 的資料夾；回傳「清單順序」
/// 的寬高比（GifStore.list 是照修改時間新到舊）
List<double> _writeGifs(int n) {
  for (final f in _gifDir.listSync().whereType<File>()) {
    f.deleteSync();
  }
  for (var i = 0; i < n; i++) {
    final (w, h) = _gifSizes[i % _gifSizes.length];
    final enc = img.GifEncoder(numColors: 32, samplingFactor: 30);
    enc.addFrame(_frame(w, h, i), duration: 8);
    enc.addFrame(_frame(w, h, i + 9), duration: 8);
    File('${_gifDir.path}${Platform.pathSeparator}gif_$i.gif')
      ..writeAsBytesSync(enc.finish()!)
      ..setLastModifiedSync(DateTime(2026).add(Duration(days: i)));
  }
  return [
    for (var i = n - 1; i >= 0; i--)
      _gifSizes[i % _gifSizes.length].$1 / _gifSizes[i % _gifSizes.length].$2,
  ];
}

/// 影片草稿的封面比例：偶數直片 9:16、奇數橫片 16:9
double _draftAspect(int i) => i.isEven ? 9 / 16 : 16 / 9;

/// 種 [drafts] 份有封面的影片草稿（索引照 DraftStore 的格式，新到舊＝
/// p0、p1…）；[photo] 再加一份照片草稿
void _seed({int drafts = 0, bool photo = false}) {
  final now = DateTime(2026, 8, 20, 12);
  final metas = <Map<String, dynamic>>[];
  final data = <String, Object>{
    'wm_presets_seeded_v1': true,
    'wm_presets_seeded_v2': true,
    'wm_presets_seeded_v3': true,
    'wm_presets_seeded_v4': true,
  };
  for (var i = 0; i < drafts; i++) {
    final id = 'p$i';
    final at = now.subtract(Duration(minutes: i * 17)).toIso8601String();
    metas.add({
      'id': id,
      'createdAt': at,
      'savedAt': at,
      'hasThumb': true,
      'thumbAspect': _draftAspect(i),
      'clips': 1,
      'dur': 5.0,
    });
    data['project_data_$id'] = jsonEncode({
      'savedAt': at,
      'clips': [
        {'id': 1},
      ],
    });
    data['project_thumb_$id'] = _pngB64;
  }
  if (drafts > 0) data['projects_index_v1'] = jsonEncode(metas);
  if (photo) {
    data[kPhotoDraftKey] = jsonEncode({
      'photo': '${_docs.path}${Platform.pathSeparator}x.jpg',
      'savedAt': now.toIso8601String(),
    });
  }
  SharedPreferences.setMockInitialValues(data);
}

/// SharedPreferences、讀檔、解碼都是真的非同步，要 runAsync 才推得動
Future<void> _settle(WidgetTester t, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

/// 比例是非同步量出來的，量到了版面會重排；等可捲距離連續 20 格不動
Future<void> _settleLayout(WidgetTester t) async {
  var last = -1.0;
  var same = 0;
  for (var i = 0; i < 300 && same < 20; i++) {
    await _settle(t, 1);
    final now = t
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .maxScrollExtent;
    same = now == last ? same + 1 : 0;
    last = now;
  }
}

/// 真的 iPhone 14：邏輯 390×844、dpr 3、瀏海 47＋home 條 34
Future<void> _pump(WidgetTester t, Widget page) async {
  t.view.devicePixelRatio = _dpr;
  t.view.physicalSize = const Size(_w * _dpr, 844 * _dpr);
  t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
  t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      debugShowCheckedModeBanner: false,
      home: LightPage(child: page),
    ),
  );
  await _settle(t);
}

/// 這個 Image 是照哪個寬度解碼的（沒縮圖解碼＝null）
int? _decodeWidth(Element e) {
  final provider = (e.widget as Image).image;
  return provider is ResizeImage ? provider.width : null;
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    _docs = Directory.systemTemp.createTempSync('markcut_tile_decode');
    _gifDir = Directory('${_docs.path}${Platform.pathSeparator}gifs')
      ..createSync(recursive: true);
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _docs.path,
    );
  });

  tearDownAll(() {
    try {
      _docs.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('草稿夾', () {
    testWidgets('封面照欄寬解碼；看不到的格子不做出來；磚是超橢圓', (t) async {
      _seed(drafts: 30);
      _writeGifs(0);
      await _pump(t, const DraftsScreen());
      await _settle(t, 30);

      // 兩欄、左右各 16、中間 10（跟畫面裡的算式同一份）
      const colW = (_w - 16 * 2 - 10) / 2;
      final covers = find.byType(Image);
      final built = covers.evaluate().length;
      expect(built, greaterThan(2), reason: '看得到的那幾格沒做出來');
      expect(built, lessThan(30), reason: '三十張封面全部做出來了（不是 lazy）');
      for (final e in covers.evaluate()) {
        expect(
          _decodeWidth(e),
          (colW * _dpr).round(),
          reason: '封面沒有照欄寬解碼（cacheWidth）',
        );
      }
      expect(find.byType(ClipRSuperellipse), findsNWidgets(built));
      expect(find.byType(ClipRRect), findsNothing, reason: '還有普通圓弧角的磚');

      // 捲到底也還是好好的
      await t.drag(find.byType(Scrollable).first, const Offset(0, -6000));
      await _settle(t, 10);
      expect(t.takeException(), isNull);
    });

    testWidgets('列表卡（照片草稿）：InkWell 上面有自己的 Material，水波畫得出來', (t) async {
      _seed(photo: true);
      _writeGifs(0);
      await _pump(t, const DraftsScreen());
      await _settle(t);

      final ink = find.widgetWithText(InkWell, '未完成的照片');
      expect(ink, findsOneWidget);
      final mat = t.widget<Material>(
        find.ancestor(of: ink, matching: find.byType(Material)).first,
      );
      expect(
        mat.shape,
        isA<RoundedSuperellipseBorder>(),
        reason: '最近的 Material 是 Scaffold 的：水波畫在卡片底色下面，按了沒回饋',
      );
      expect(find.byType(ClipRRect), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('我的 GIF', () {
    testWidgets('磚照欄寬解碼、比例量得對、磚是超橢圓', (t) async {
      _seed();
      final aspects = _writeGifs(6);
      await _pump(t, const GifsScreen());
      await _settleLayout(t);

      const colW = (_w - 16 * 2 - 10) / 2;
      final tiles = find.byType(GifImage);
      expect(tiles, findsNWidgets(aspects.length));
      // widget tree 的順序是「第 0 欄由上到下，再第 1 欄」：
      // 照舊的排法（丟進比較短的那一欄）推回每一格是哪一個
      final col = <int>[];
      final h = [0.0, 0.0];
      for (final a in aspects) {
        final c = h[0] <= h[1] ? 0 : 1;
        col.add(c);
        h[c] += colW / a + 10;
      }
      final order = [
        for (var i = 0; i < aspects.length; i++)
          if (col[i] == 0) i,
        for (var i = 0; i < aspects.length; i++)
          if (col[i] == 1) i,
      ];
      for (var k = 0; k < order.length; k++) {
        final r = t.getRect(tiles.at(k));
        expect(
          r.width / r.height,
          moreOrLessEquals(aspects[order[k]], epsilon: 0.01),
          reason: '第 ${order[k]} 格的比例量錯了',
        );
        final image = find.descendant(
          of: tiles.at(k),
          matching: find.byType(Image),
        );
        expect(
          _decodeWidth(image.evaluate().single),
          (colW * _dpr).round(),
          reason: '第 ${order[k]} 格沒有照欄寬解碼',
        );
      }
      expect(find.byType(ClipRSuperellipse), findsNWidgets(aspects.length));
      expect(find.byType(ClipRRect), findsNothing, reason: '還有普通圓弧角的磚');
      expect(t.takeException(), isNull);
    });
  });

  group('個人中心', () {
    testWidgets('草稿封面與 GIF 磚都照磚的尺寸解碼；磚是超橢圓；只讀畫得到的兩張封面', (t) async {
      _seed(drafts: 3);
      final aspects = _writeGifs(3);
      await _pump(t, const ProfileScreen());
      await _settle(t, 30);

      // 草稿卡：兩欄、3:4，封面 cover 進去——直片貼寬、橫片貼高
      const inner = _w - 22 * 2;
      const cardW = (inner - 12) / 2;
      const cardH = cardW * 4 / 3;
      final covers = find.descendant(
        of: find.byType(AspectRatio),
        matching: find.byType(Image),
      );
      expect(covers, findsNWidgets(2), reason: '主頁最多兩張卡');
      for (final (i, e) in covers.evaluate().indexed) {
        final want = math.max(cardW, cardH * _draftAspect(i)) * _dpr;
        expect(_decodeWidth(e), want.round(), reason: '第 $i 張封面的解碼寬度不對');
      }

      // GIF 磚：正方，cover 進去——橫的要貼高（寬＝格寬×比例）
      const cell = (inner - 20) / 3;
      final gifs = find.byType(GifImage);
      expect(gifs, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        final image = find.descendant(
          of: gifs.at(i),
          matching: find.byType(Image),
        );
        final want = cell * math.max(1.0, aspects[i]) * _dpr;
        expect(
          _decodeWidth(image.evaluate().single),
          want.round(),
          reason: '第 $i 格 GIF 的解碼寬度不對',
        );
      }

      // 兩張草稿卡＋三塊 GIF 磚＋（沒有範本，只有＋磚）：全部超橢圓
      expect(find.byType(ClipRSuperellipse), findsNWidgets(5));
      expect(find.byType(ClipRRect), findsNothing, reason: '還有普通圓弧角的磚');
      expect(t.takeException(), isNull);
    });

    testWidgets('空狀態的灰字用 kLTextDim', (t) async {
      _seed();
      _writeGifs(0);
      await _pump(t, const ProfileScreen());
      for (final s in const ['還沒有草稿', '還沒有 GIF']) {
        expect(
          t.widget<Text>(find.text(s)).style?.color,
          kLTextDim,
          reason: '「$s」的灰在白底上對比不夠',
        );
      }
      expect(t.takeException(), isNull);
    });
  });
}
