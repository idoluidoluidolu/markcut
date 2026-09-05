// 照片拼圖改成「一個畫面、三個分頁（拼圖／浮水印／匯出）」之後的守門：
//
// - 三個分頁依序存在、切來切去宮格狀態不掉
// - 浮水印分頁：共用面板在下面、浮水印圖層疊在拼圖預覽上、拖得動
// - 合成：空格子透明、浮水印畫得進去、存 PNG 一路保留透明
//   （朋友回報過透明組圖被強制上白底，不能再發生）
// - 草稿：浮水印設定跟拼圖一起存、一起回來
// - 離開保護：匯出成功過就靜靜留草稿走人；沒匯出過才問保留／捨棄
// - 「完成，上浮水印」那顆鈕與交給照片編輯器的那條路都不在了
import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/nav.dart';
import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/services/collage_compose.dart';
import 'package:markcut/widgets/watermark_layer.dart';
import 'package:markcut/widgets/watermark_panel.dart';

Future<ui.Image> _img(Color c, int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = c,
  );
  return rec.endRecording().toImage(w, h);
}

Future<Uint8List> _png(Color c, int w, int h) async {
  final img = await _img(c, w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

const _red = Color(0xFFFF0000);
const _blue = Color(0xFF0000FF);

/// 兩張測試照片（圖片編解碼是真非同步，要包 runAsync 才會完成）
Future<List<XFile>> _twoPhotos(WidgetTester t) async {
  late Uint8List a, b;
  await t.runAsync(() async {
    a = await _png(_red, 300, 200);
    b = await _png(_blue, 200, 300);
  });
  return [
    XFile.fromData(a, name: 'a.png', mimeType: 'image/png'),
    XFile.fromData(b, name: 'b.png', mimeType: 'image/png'),
  ];
}

/// 等 _load 讀檔＋解碼完成（輪詢直到轉圈圈消失）
Future<void> _waitLoaded(WidgetTester t) async {
  for (
    var i = 0;
    i < 50 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    i++
  ) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await t.pump();
  }
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

/// 從一個假的首頁把拼圖頁 push 出去：離開保護要能真的 pop 回來
Future<void> _pumpFromHome(WidgetTester t, Widget screen) async {
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () =>
                  Navigator.push(ctx, editRoute(builder: (_) => screen)),
              child: const Text('首頁'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('首頁'));
  // 不用 pumpAndSettle：拼圖頁載入中的轉圈圈永遠不會停
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await _waitLoaded(t);
}

/// 底部分頁列上的那一格
Finder _tab(String label) =>
    find.descendant(of: find.byType(TabBar), matching: find.text(label));

Future<void> _goTab(WidgetTester t, String label) async {
  await t.tap(_tab(label));
  await t.pumpAndSettle();
}

/// 匯出分頁裡那顆膠囊鈕（分頁列上也有一個「匯出」字，要避開）
Finder _exportButton() => find.ancestor(
  of: find.text('匯出'),
  matching: find.byWidgetPredicate((w) => w is FilledButton),
);

/// 返回鍵：走 PopScope（跟實機按返回鍵同一條路）
Future<void> _back(WidgetTester t) async {
  unawaited(t.state<NavigatorState>(find.byType(Navigator)).maybePop());
  await t.pumpAndSettle();
}

WatermarkSettings _liveWm(WidgetTester t) =>
    t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).settings;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('三個分頁依序是 拼圖／浮水印／匯出；切來切去宮格狀態不會掉', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(
      MaterialApp(home: CollageScreen(photos: await _twoPhotos(t))),
    );
    await _waitLoaded(t);

    // 分頁列：三格都在、順序固定、都在底部
    final xs = [for (final l in ['拼圖', '浮水印', '匯出']) t.getCenter(_tab(l)).dx];
    expect(xs[0] < xs[1] && xs[1] < xs[2], isTrue, reason: '順序要是 拼圖／浮水印／匯出');
    final screen = t.getRect(find.byType(Scaffold));
    expect(t.getCenter(_tab('拼圖')).dy, greaterThan(screen.bottom - 80));

    // 舊流程的鈕都不在了
    expect(find.text('完成，上浮水印'), findsNothing);
    expect(find.textContaining('匯入照片'), findsNothing);
    expect(find.textContaining('進階編輯'), findsNothing);

    // 兩張 → 2×1 排滿：只有欄／列兩顆加號。把欄加成 3 就多一個空格的「＋」
    expect(find.byIcon(Icons.add), findsNWidgets(2));
    await t.tap(find.byIcon(Icons.add).first);
    await t.pumpAndSettle();
    expect(find.byIcon(Icons.add), findsNWidgets(3));
    expect(find.text('3'), findsOneWidget, reason: '欄的讀數');

    // 切去浮水印：設定卡收掉、面板出來；再切回來：3 欄與空格都還在
    await _goTab(t, '浮水印');
    expect(find.byType(WatermarkPanel), findsOneWidget);
    expect(find.text('版型'), findsNothing);
    await _goTab(t, '匯出');
    expect(find.byType(WatermarkPanel), findsNothing);
    expect(_exportButton(), findsOneWidget);
    await _goTab(t, '拼圖');
    expect(find.text('版型'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNWidgets(3));
    // 三個分頁的預覽都是同一個拼圖畫布
    expect(find.byType(AspectRatio), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('浮水印分頁：面板在下面、浮水印圖層剛好蓋在拼圖預覽上，拖得動', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(
      MaterialApp(home: CollageScreen(photos: await _twoPhotos(t))),
    );
    await _waitLoaded(t);
    await _goTab(t, '浮水印');

    expect(find.byType(WatermarkPanel), findsOneWidget);
    final layer = find.byType(WatermarkLayer);
    expect(layer, findsOneWidget);
    final canvas = t.getRect(find.byType(AspectRatio).first);
    expect(t.getRect(layer), canvas, reason: '浮水印圖層要剛好蓋住拼圖畫布');
    // 面板知道畫布比例（九宮格「貼邊」才夾得準）
    expect(
      t.widget<WatermarkPanel>(find.byType(WatermarkPanel)).canvasAspect,
      closeTo(1.0, 1e-9),
    );
    // 面板跟圖層綁的是同一組設定
    expect(
      identical(
        t.widget<WatermarkPanel>(find.byType(WatermarkPanel)).settings,
        _liveWm(t),
      ),
      isTrue,
    );

    // 沒選取：從文字（預設在正中央）往右下拖，文字要跟著走
    final s = _liveWm(t);
    final before = (s.text.x, s.text.y);
    var g = await t.startGesture(canvas.center);
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(6, 5));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump();
    expect(s.text.x, greaterThan(before.$1 + 0.05));
    expect(s.text.y, greaterThan(before.$2 + 0.05));

    // 點文字＝選取：琥珀框畫在外層（拖出畫面也看得到）
    final textAt = Offset(
      canvas.left + canvas.width * s.text.x,
      canvas.top + canvas.height * s.text.y,
    );
    await t.tapAt(textAt);
    // 圖層上有雙擊判定，單擊要等雙擊的等待時間過了才成立
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    final overlay = t.widget<WmFrameOverlay>(find.byType(WmFrameOverlay));
    expect(overlay.info.value, isNotNull, reason: '選取框要回報給外層畫');

    // 選取中：從畫布空白處拖也只動被選的文字（選取路由）
    final x1 = s.text.x;
    g = await t.startGesture(Offset(canvas.left + 12, canvas.top + 12));
    await t.pump(const Duration(milliseconds: 20));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(-6, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pump();
    expect(s.text.x, lessThan(x1 - 0.03));

    // 切去拼圖分頁：浮水印還在畫面上（只看不動），但選取框收掉
    await _goTab(t, '拼圖');
    expect(find.byType(WatermarkLayer), findsOneWidget);
    expect(find.byType(WmFrameOverlay), findsNothing);
    expect(t.takeException(), isNull);
  });

  test('合成：空格子透明、浮水印畫得進去、存 PNG 一路保留透明', () async {
    final red = await _img(const Color(0xFF802020), 120, 80);
    final blue = await _img(const Color(0xFF203080), 80, 120);
    final green = await _img(const Color(0xFF208030), 100, 100);
    // 2×2、右下角空著
    final layout = CollageLayout(
      free: false,
      cols: 2,
      rows: 2,
      order: const [0, 1, 2, -1],
      fits: [for (var i = 0; i < 4; i++) CollageCellFit()],
      items: const [],
      canvasAspect: 1,
    );
    final wm = WatermarkSettings();
    wm.text
      ..text = 'WM'
      ..x = 0.25
      ..y = 0.25
      ..sizeFrac = 0.2;
    final images = [red, blue, green];
    const n = 200;
    final plain = await composeCollage(layout, images, longSide: n.toDouble());
    final marked = await composeCollage(
      layout,
      images,
      watermark: wm,
      longSide: n.toDouble(),
    );
    expect((marked.width, marked.height), (n, n));
    final p = (await plain.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    final m = (await marked.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    int alpha(Uint8List px, int x, int y) => px[(y * n + x) * 4 + 3];

    // 三個有照片的格子中心不透明；空格（右下）整格一個像素都沒碰到
    expect(alpha(m, 50, 50), 255);
    expect(alpha(m, 150, 50), 255);
    expect(alpha(m, 50, 150), 255);
    for (var y = 100; y < n; y++) {
      for (var x = 100; x < n; x++) {
        expect(alpha(m, x, y), 0, reason: '空格 ($x,$y) 應該是透明的');
      }
    }
    // 浮水印真的畫上去了：左上那格有一堆像素跟沒浮水印的版本不一樣
    var diff = 0;
    for (var y = 0; y < 100; y++) {
      for (var x = 0; x < 100; x++) {
        final o = (y * n + x) * 4;
        if (m[o] != p[o] || m[o + 1] != p[o + 1] || m[o + 2] != p[o + 2]) {
          diff++;
        }
      }
    }
    expect(diff, greaterThan(50), reason: '浮水印文字要出現在左上格');

    // 存成 PNG 再解回來：透明還在（不能烙白底）
    final png = (await marked.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    final codec = await ui.instantiateImageCodec(png);
    final back = (await codec.getNextFrame()).image;
    final b = (await back.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    expect(alpha(b, 150, 150), 0);
    expect(alpha(b, 50, 50), 255);
    for (final i in [plain, marked, back, ...images]) {
      i.dispose();
    }
  });

  test('合成：自由模式沒被照片蓋到的地方透明、方塊出血被裁掉', () async {
    final red = await _img(const Color(0xFF802020), 100, 100);
    final layout = CollageLayout(
      free: true,
      cols: 0,
      rows: 0,
      order: const [],
      fits: const [],
      items: [
        // 左上 1/4 一塊，另一塊拉出畫布外
        CollageFreeItem(img: 0, rect: const Rect.fromLTWH(0, 0, 0.5, 0.5)),
        CollageFreeItem(img: 0, rect: const Rect.fromLTWH(0.8, 0.8, 0.5, 0.5)),
      ],
      canvasAspect: 1,
    );
    const n = 100;
    final out = await composeCollage(layout, [red], longSide: n.toDouble());
    final px = (await out.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    int alpha(int x, int y) => px[(y * n + x) * 4 + 3];
    expect(alpha(25, 25), 255);
    expect(alpha(75, 25), 0);
    expect(alpha(25, 75), 0);
    expect(alpha(90, 90), 255);
    out.dispose();
    red.dispose();
  });

  test('輸出尺寸：自由 2048、宮格照格數 1600~2400、另一邊照畫布比例', () {
    CollageLayout l({
      bool free = false,
      int cols = 2,
      int rows = 2,
      double aspect = 1,
    }) => CollageLayout(
      free: free,
      cols: cols,
      rows: rows,
      order: const [],
      fits: const [],
      items: const [],
      canvasAspect: aspect,
    );
    expect(collageLongSide(l(free: true)), 2048);
    expect(collageLongSide(l()), 1600);
    expect(collageLongSide(l(cols: 6, rows: 6)), 2400);
    expect(collageCanvasSize(l(aspect: 0.8), 1600), (1280, 1600));
    expect(collageCanvasSize(l(aspect: 16 / 9), 1600), (1600, 900));
    expect(collageCanvasSize(l(free: true), 2048), (2048, 2048));
  });

  testWidgets('草稿：浮水印設定跟著拼圖一起存、續作時一起回來（個人頁讀得到）', (t) async {
    SharedPreferences.setMockInitialValues({});
    // 草稿續作靠檔案路徑，用真的暫存檔
    final dir = Directory.systemTemp.createTempSync('collage_wm_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final pa = '${dir.path}${Platform.pathSeparator}a.png';
    final pb = '${dir.path}${Platform.pathSeparator}b.png';
    await t.runAsync(() async {
      File(pa).writeAsBytesSync(await _png(_red, 300, 200));
      File(pb).writeAsBytesSync(await _png(_blue, 200, 300));
    });

    await _pumpFromHome(t, CollageScreen(photos: [XFile(pa), XFile(pb)]));
    await _goTab(t, '浮水印');
    _liveWm(t).text
      ..text = '拼圖草稿'
      ..x = 0.2
      ..y = 0.8;
    await t.pump();

    // 返回：沒匯出過 → 問保留／捨棄；保留＝存草稿、回首頁
    await _back(t);
    expect(find.text('這份拼圖還沒完成'), findsOneWidget);
    expect(find.text('保留草稿'), findsOneWidget);
    await t.tap(find.text('保留草稿'));
    await t.pumpAndSettle();
    expect(find.text('首頁'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kCollageDraftKey);
    expect(raw, isNotNull);
    final draft = jsonDecode(raw!) as Map<String, dynamic>;
    // 個人頁「草稿」列表靠 photos 非空與 savedAt 判斷／標時間
    expect((draft['photos'] as List).length, 2);
    expect(draft['savedAt'], isA<String>());
    expect(draft['wm'], isA<Map>());
    final wmJson = WatermarkSettings.fromJson(
      Map<String, dynamic>.from(draft['wm'] as Map),
    );
    expect(wmJson.text.text, '拼圖草稿');

    // 續作（個人頁走 CollageScreen(restore: draft)）：照片與浮水印都回來
    await _pumpFromHome(t, CollageScreen(restore: draft));
    expect(find.byIcon(Icons.add), findsNWidgets(2), reason: '兩張照片都回來、沒有空格');
    await _goTab(t, '浮水印');
    final s = _liveWm(t);
    expect(s.text.text, '拼圖草稿');
    expect(s.text.x, closeTo(0.2, 1e-9));
    expect(s.text.y, closeTo(0.8, 1e-9));
    expect(t.takeException(), isNull);
  });

  testWidgets('匯出：只問一個格式視窗、拼圖＋浮水印一次存相簿（空格透明）；匯出過離開不再問', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    // 相簿由 gal 套件寫入，測試裡接住它的通道拿到最後存出去的位元組
    Uint8List? saved;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const gal = MethodChannel('gal');
    messenger.setMockMethodCallHandler(gal, (call) async {
      switch (call.method) {
        case 'hasAccess':
        case 'requestAccess':
          return true;
        case 'putImageBytes':
          saved = (call.arguments as Map)['bytes'] as Uint8List;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(gal, null));

    await _pumpFromHome(t, CollageScreen(photos: await _twoPhotos(t)));
    // 2×1 → 欄加成 3：留一個空格，匯出那一格要透明
    await t.tap(find.byIcon(Icons.add).first);
    await t.pumpAndSettle();
    // 浮水印縮小、擺到左邊那格上（預設文字置中很寬，會壓到空格）
    await _goTab(t, '浮水印');
    _liveWm(t).text
      ..x = 0.15
      ..y = 0.5
      ..sizeFrac = 0.06;
    await t.pump();

    await _goTab(t, '匯出');
    expect(find.textContaining('1600×1600'), findsOneWidget, reason: '畫布尺寸列');
    expect(find.text('2 張'), findsOneWidget);
    // 已經在匯出分頁再按一次「匯出」＝直接開始（跟影片編輯器同一個手感）
    await t.tap(_tab('匯出'));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget, reason: '一次只能跳一個視窗');
    expect(find.text('輸出到相簿'), findsOneWidget, reason: '跳的要是照片格式那個');
    expect(find.text('JPEG'), findsOneWidget);
    expect(find.text('PNG 無損'), findsOneWidget);
    expect(find.text('畫質'), findsNothing);

    await t.tap(find.text('PNG 無損'));
    await t.pump();
    // 合成＋編碼是真非同步：等到「匯出完成」出現
    for (var i = 0; i < 150 && find.text('匯出完成').evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('匯出完成'), findsOneWidget);
    expect(saved, isNotNull, reason: '要真的走到存相簿那一步');

    // 存出去的 PNG：1600×1600、空格那一格透明、左格上有浮水印（不是純紅）
    late int w, h;
    late Uint8List px;
    await t.runAsync(() async {
      final codec = await ui.instantiateImageCodec(saved!);
      final img = (await codec.getNextFrame()).image;
      w = img.width;
      h = img.height;
      px = (await img.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      img.dispose();
    });
    expect((w, h), (1600, 1600));
    int at(int x, int y, int c) => px[(y * w + x) * 4 + c];
    expect(at(1333, 800, 3), 0, reason: '第三格是空的，要透明');
    expect(at(1333, 200, 3), 0);
    expect(at(267, 100, 3), 255, reason: '第一格有照片');
    expect(at(800, 100, 3), 255, reason: '第二格有照片');
    // 浮水印落在左格中央附近：那裡不該還是一片純紅
    var notRed = 0;
    for (var y = 700; y < 900; y += 4) {
      for (var x = 100; x < 400; x += 4) {
        if (!(at(x, y, 0) == 255 && at(x, y, 1) == 0 && at(x, y, 2) == 0)) {
          notRed++;
        }
      }
    }
    expect(notRed, greaterThan(20), reason: '浮水印要畫在成品上');

    await t.tap(find.text('繼續編輯'));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    // 匯出成功過：返回不再問，草稿靜靜留著，直接回首頁
    await _back(t);
    expect(find.text('保留草稿'), findsNothing);
    expect(find.text('首頁'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kCollageDraftKey), isNotNull, reason: '匯出過的草稿留著');
    expect(t.takeException(), isNull);
  });

  testWidgets('離開保護：沒匯出過就問「保留草稿／捨棄」；捨棄＝草稿清掉、回首頁', (t) async {
    SharedPreferences.setMockInitialValues({
      kCollageDraftKey: '{"photos":["old"]}',
    });
    await _pumpFromHome(t, CollageScreen(photos: await _twoPhotos(t)));
    await _back(t);
    expect(find.text('保留草稿'), findsOneWidget);
    expect(find.text('捨棄'), findsOneWidget);
    expect(find.text('首頁'), findsNothing);
    await t.tap(find.text('捨棄'));
    await t.pumpAndSettle();
    expect(find.text('首頁'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kCollageDraftKey), isNull);
  });

  testWidgets('空手進場：三個分頁都能切；沒照片按匯出只提示，不跳視窗', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(const MaterialApp(home: CollageScreen()));
    await _waitLoaded(t);
    // 2×2 空盤：四個空格的「＋」加欄／列兩顆
    expect(find.byIcon(Icons.add), findsNWidgets(6));
    // 照片還沒放也能先調浮水印（跟影片編輯器一樣）
    await _goTab(t, '浮水印');
    expect(find.byType(WatermarkPanel), findsOneWidget);
    await _goTab(t, '匯出');
    expect(find.text('還沒放照片'), findsOneWidget);
    await t.tap(_exportButton());
    await t.pump();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('先加幾張照片再匯出'), findsOneWidget);
    // 提示卡的計時器跑完，不留 pending timer
    await t.pump(const Duration(seconds: 3));
    expect(t.takeException(), isNull);
  });

  test('「完成，上浮水印」與交給照片編輯器的那條路都拿掉了（掃原始碼）', () {
    final src = File('lib/screens/collage_screen.dart').readAsStringSync();
    expect(src.contains('完成，上浮水印'), isFalse);
    expect(src.contains('還有空格子'), isFalse);
    expect(src.contains('photo_editor_screen.dart'), isFalse);
    expect(src.contains('PhotoEditorScreen'), isFalse);
    // 匯出走照片共用的那條路，浮水印走共用面板與圖層
    expect(src.contains('askPhotoFormat('), isTrue);
    expect(src.contains('savePhotoImage('), isTrue);
    expect(src.contains('askAfterExport('), isTrue);
    expect(src.contains('WatermarkPanel('), isTrue);
    expect(src.contains('WatermarkLayer('), isTrue);
  });

  testWidgets('切進浮水印分頁就自動選好浮水印（有框、面板對得上）；點空白才取消', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(
      MaterialApp(home: CollageScreen(photos: await _twoPhotos(t))),
    );
    await _waitLoaded(t);
    await _goTab(t, '浮水印');
    // 一進來就是選取狀態：圖層知道選的是文字、外層有框
    expect(
      t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).selectedPart,
      WmPart.text,
    );
    await t.pump();
    final overlay = t.widget<WmFrameOverlay>(find.byType(WmFrameOverlay));
    expect(overlay.info.value, isNotNull, reason: '進來就該有選取框');

    // 點在被選的文字框裡：維持選取（不是取消）
    final frame = overlay.info.value!.rect;
    final canvas = t.getRect(find.byType(AspectRatio).first);
    await t.tapAt(canvas.topLeft + frame.center);
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(overlay.info.value, isNotNull, reason: '點自己不該取消選取');

    // 點畫布上遠離文字的空白：取消
    await t.tapAt(Offset(canvas.left + 10, canvas.top + 10));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(find.byType(WmFrameOverlay), findsOneWidget);
    expect(
      t.widget<WmFrameOverlay>(find.byType(WmFrameOverlay)).info.value,
      isNull,
      reason: '點空白要取消選取',
    );
    // 取消之後留在這一頁不會被硬選回去（只有「剛切進來」那一下會自動選）
    await t.pump(const Duration(milliseconds: 300));
    expect(
      t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).selectedPart,
      WmPart.none,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('拼圖分頁點到浮水印框內：自動選取並切到浮水印分頁；框外照樣是格子', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(
      MaterialApp(home: CollageScreen(photos: await _twoPhotos(t))),
    );
    await _waitLoaded(t);
    expect(find.text('版型'), findsOneWidget, reason: '起手在拼圖分頁');

    // 預設文字浮水印在畫布正中央：點那裡
    final canvas = t.getRect(find.byType(AspectRatio).first);
    await t.tapAt(canvas.center);
    // 圖層上有雙擊判定，單擊要等雙擊的等待時間過了才成立
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(find.byType(WatermarkPanel), findsOneWidget, reason: '要切到浮水印分頁');
    expect(find.text('版型'), findsNothing);
    expect(
      t.widget<WatermarkLayer>(find.byType(WatermarkLayer)).selectedPart,
      WmPart.text,
      reason: '帶著選取一起過去',
    );
    expect(t.widget<WmFrameOverlay>(find.byType(WmFrameOverlay)).info.value, isNotNull);

    // 回拼圖分頁，點遠離浮水印的角落（格子）：不會被切走
    await _goTab(t, '拼圖');
    await t.tapAt(Offset(canvas.left + 8, canvas.top + 8));
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    expect(find.text('版型'), findsOneWidget, reason: '框外的點擊照樣是拼圖的');
    expect(t.takeException(), isNull);
  });
}
