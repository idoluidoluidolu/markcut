// 個人中心（＋草稿夾、我的 GIF）「捲一格要幾毫秒」的量尺。預設略過，
// 不進一般測試。
//
// 跑法（PowerShell）：
//   $env:MARKCUT_BENCH='1'; flutter test --no-pub test/perf/profile_scroll_bench_test.dart
// 跑法（bash）：
//   MARKCUT_BENCH=1 flutter test --no-pub test/perf/profile_scroll_bench_test.dart
//
// 量的是 UI 執行緒的 build / layout / compositing / paint 四段（widget
// test 不上 GPU，光柵化那段量不到）。捲動時 build 跟 layout 幾乎是 0——
// SingleChildScrollView 捲動只叫 markNeedsPaint——所以 paint 那一欄就是
// 「這一頁捲一格要重畫多少東西」。
//
// 另外量一件事：**一張 GIF 換格的重畫波及範圍**。動圖每換一格會對自己的
// RenderImage markNeedsPaint，往上找到最近的 repaint boundary 才停；中間
// 沒有 RepaintBoundary 的話，整個捲動內容（含範本磚的文字排版）就跟著
// 重畫一次——而且是在沒有人碰螢幕的時候。這一欄是 markNeedsPaint 一張圖
// 之後 flushPaint 的耗時。
//
// 桌機數字不是 iPhone 數字，看的是「每格幾毫秒」對 16.7ms 預算的比例，
// 以及改前改後的差。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/photo_editor_screen.dart' show kPhotoDraftKey;
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/watermark_layer.dart';

final _bench = Platform.environment['MARKCUT_BENCH'] == '1';

late final String _tmpDir;

/// 30 份草稿的封面（720 高的 JPEG base64，跟編輯器實際存的一樣，
/// 見 video_editor_screen 的 _draftThumb / nativeFrameAt maxH: 720）
late final List<String> _covers;

const _kDrafts = 30;
const _kPresets = 12;
const _kGifs = 40;

String _stats(String name, List<int> us) {
  final s = List.of(us)..sort();
  final med = s[s.length ~/ 2];
  final p90 = s[(s.length * 0.9).floor().clamp(0, s.length - 1)];
  final avg = s.reduce((a, b) => a + b) / s.length;
  final over = s.where((v) => v > 16700).length;
  String ms(num v) => (v / 1000).toStringAsFixed(2);
  return '${name.padRight(34)} med ${ms(med).padLeft(6)}ms  '
      'p90 ${ms(p90).padLeft(6)}ms  avg ${ms(avg).padLeft(6)}ms  '
      'max ${ms(s.last).padLeft(6)}ms  >16.7ms ${over.toString().padLeft(2)}/${s.length}';
}

/// 讓非同步的圖片解碼／SharedPreferences 真的跑完
Future<void> _settle(WidgetTester t, [int n = 25]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

int _countEl(Element e) {
  var k = 1;
  e.visitChildren((c) => k += _countEl(c));
  return k;
}

int _countRo(RenderObject r) {
  var k = 1;
  r.visitChildren((c) => k += _countRo(c));
  return k;
}

int _countBoundaries(RenderObject r) {
  var k = r.isRepaintBoundary ? 1 : 0;
  r.visitChildren((c) => k += _countBoundaries(c));
  return k;
}

/// 一張有雜訊的假影格（純色會讓 JPEG 壓得不真實地小）
img.Image _frame(int w, int h, int seed) {
  final im = img.Image(width: w, height: h);
  var s = 0x9E3779B9 ^ seed;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      s ^= s << 13;
      s ^= s >>> 17;
      s ^= s << 5;
      s &= 0xFFFFFFFF;
      final n = s & 0x3F;
      im.setPixelRgb(
        x,
        y,
        (x * 255 ~/ w) ~/ 2 + n,
        (y * 255 ~/ h) ~/ 2 + n,
        ((seed * 37) & 0xFF) ~/ 2 + n,
      );
    }
  }
  return im;
}

/// 一組像使用者自己做的範本：文字有陰影、有加粗、透明度 < 1
/// （＝畫的時候要開 saveLayer、要排版好幾次，見 text_mark_painter）
WatermarkPreset _preset(int i) => WatermarkPreset(
  name: '範本 $i',
  settings: WatermarkSettings(
    text: TextMark(
      text: '@我的頻道 $i',
      fontFamily: 'NotoSansTC',
      colorValue: 0xFFFFFFFF,
      opacity: 0.85,
      sizeFrac: 0.11,
      x: 0.5,
      y: 0.5,
      rotation: i.isEven ? 0 : -12,
      shadow: true,
      shadowOpacity: 0.75,
      weight: 0.5,
    ),
  ),
);

void _seed({int drafts = _kDrafts, int presets = _kPresets}) {
  final now = DateTime.now();
  final metas = <Map<String, dynamic>>[];
  final data = <String, Object>{};
  for (var i = 0; i < drafts; i++) {
    final id = 'p$i';
    metas.add({
      'id': id,
      'createdAt': now.subtract(Duration(hours: i * 3)).toIso8601String(),
      'savedAt': now.subtract(Duration(minutes: i * 17)).toIso8601String(),
      'hasThumb': true,
      // 直片、橫片混在一起：瀑布流兩欄的高度才不一樣
      'thumbAspect': i % 3 == 0 ? 16 / 9 : 9 / 16,
      'clips': 3 + i % 5,
      'dur': 12.0 + i,
    });
    data['project_data_$id'] = jsonEncode({
      'savedAt': now.subtract(Duration(minutes: i * 17)).toIso8601String(),
      'clips': [
        {'id': 1},
      ],
    });
    data['project_thumb_$id'] = _covers[i % _covers.length];
  }
  SharedPreferences.setMockInitialValues({
    'wm_presets_v1': [for (var i = 0; i < presets; i++) _preset(i).encode()],
    'wm_presets_seeded_v1': true,
    'wm_presets_seeded_v2': true,
    'wm_presets_seeded_v3': true,
    'projects_index_v1': jsonEncode(metas),
    ...data,
    // 照片草稿也在（個人中心的草稿區會多一張卡）
    kPhotoDraftKey: jsonEncode({
      'savedAt': now.toIso8601String(),
      'photo': '$_tmpDir${Platform.pathSeparator}photo.jpg',
    }),
  });
}

/// 捲一頁：每一格拖 8px，四個階段分開計時。
/// 回傳報表列
Future<List<String>> _scrollBench(WidgetTester t, String label) async {
  final rows = <String>[];
  final po = t.binding.rootPipelineOwner;
  final view = t.binding.renderViews.first;

  final scrollable = find.byType(Scrollable);
  expect(scrollable, findsWidgets, reason: '$label 找不到捲動區');
  final pos = t.state<ScrollableState>(scrollable.first).position;
  rows.add(
    '  可捲距離 ${(pos.maxScrollExtent).toStringAsFixed(0)}pt / '
    '視窗 ${pos.viewportDimension.toStringAsFixed(0)}pt',
  );

  final scrollBox = t.getRect(scrollable.first);
  rows.add(
    '  scroll view 內 element 數 ${_countEl(scrollable.first.evaluate().first)}',
  );
  final vpRo = t.renderObject(scrollable.first);
  rows.add(
    '  scroll view 內 render object 數 ${_countRo(vpRo)}'
    '（其中 repaint boundary ${_countBoundaries(vpRo)}）',
  );
  // 真的畫出來的圖有幾張（測試環境的解碼要 runAsync 才跑得動，
  // 沒解到的話「單張圖換格」那一欄就不能當真）
  final imgs = find.byType(RawImage);
  final decoded = imgs
      .evaluate()
      .where((e) => (e.widget as RawImage).image != null)
      .length;
  rows.add('  RawImage ${imgs.evaluate().length} 張（已解碼 $decoded）');
  rows.add(
    '  WatermarkLayer（範本磚）${find.byType(WatermarkLayer).evaluate().length} 個',
  );

  // 底噪：什麼都沒髒的 pump
  final idle = <int>[];
  for (var i = 0; i < 20; i++) {
    final sw = Stopwatch()..start();
    await t.pump(const Duration(milliseconds: 16));
    idle.add(sw.elapsedMicroseconds);
  }
  rows.add(_stats('  閒置 pump（底噪）', idle));

  // 一張 GIF／封面換格 → 重畫波及到哪裡。
  // 動圖每換一格就對自己的 RenderImage markNeedsPaint，往上找到最近的
  // repaint boundary 才停——中間沒有 RepaintBoundary 的話，整頁重畫
  if (imgs.evaluate().isNotEmpty) {
    final ro = t.renderObject(imgs.first);
    final blast = <int>[];
    for (var i = 0; i < 20; i++) {
      ro.markNeedsPaint();
      final sw = Stopwatch()..start();
      po.flushPaint();
      blast.add(sw.elapsedMicroseconds);
      await t.pump(const Duration(milliseconds: 16));
    }
    rows.add(_stats('  單張圖換格 → flushPaint', blast));
    // 波及範圍：那張圖髒掉之後，是誰被標成要重畫
    ro.markNeedsPaint();
    var dirty = 0;
    void census(RenderObject r) {
      if (r.debugNeedsPaint) dirty++;
      r.visitChildren(census);
    }

    census(view);
    rows.add('  單張圖髒掉 → 標記要重畫的 render object：$dirty');
    po.flushPaint();
    await t.pump(const Duration(milliseconds: 16));
  }

  // 捲動：每一格一個 move 事件，四段分開計時
  final ph = <String, List<int>>{
    'build': [],
    'layout': [],
    'compositing': [],
    'paint': [],
    'pump 其餘': [],
  };
  final total = <int>[];
  var rebuilt = 0;
  final byType = <String, int>{};

  final g = await t.startGesture(scrollBox.center);
  await t.pump(const Duration(milliseconds: 16));
  await g.moveBy(const Offset(0, -20)); // 越過拖曳門檻
  await t.pump(const Duration(milliseconds: 16));

  const n = 40;
  var dir = -1.0;
  for (var i = 0; i < n; i++) {
    // 到底就換方向，維持一直在捲
    if (pos.pixels >= pos.maxScrollExtent - 4) dir = 1;
    if (pos.pixels <= 4) dir = -1;
    if (i == n ~/ 2) {
      debugOnRebuildDirtyWidget = (e, _) {
        rebuilt++;
        final k = e.widget.runtimeType.toString();
        byType[k] = (byType[k] ?? 0) + 1;
      };
    }
    final swAll = Stopwatch()..start();
    await g.moveBy(Offset(0, 8 * dir));
    var sw = Stopwatch()..start();
    t.binding.buildOwner!.buildScope(t.binding.rootElement!);
    ph['build']!.add(sw.elapsedMicroseconds);
    if (i == n ~/ 2) debugOnRebuildDirtyWidget = null;
    sw = Stopwatch()..start();
    po.flushLayout();
    ph['layout']!.add(sw.elapsedMicroseconds);
    sw = Stopwatch()..start();
    po.flushCompositingBits();
    ph['compositing']!.add(sw.elapsedMicroseconds);
    sw = Stopwatch()..start();
    po.flushPaint();
    ph['paint']!.add(sw.elapsedMicroseconds);
    sw = Stopwatch()..start();
    await t.pump(const Duration(milliseconds: 16));
    ph['pump 其餘']!.add(sw.elapsedMicroseconds);
    total.add(swAll.elapsedMicroseconds);
  }
  await g.up();
  await t.pump();

  rows.add(_stats('  捲一格（整格）', total));
  for (final e in ph.entries) {
    rows.add(_stats('    └ ${e.key}', e.value));
  }
  final top = byType.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  rows.add(
    '  捲一格重建的 element：$rebuilt'
    '${rebuilt == 0 ? '' : '（${top.take(8).map((e) => '${e.key}x${e.value}').join(', ')}）'}',
  );
  // 用 view 讓 analyzer 知道它有用到（也順便報一下整棵樹多大）
  rows.add('  整個畫面 render object 數 ${_countRo(view)}');
  return rows;
}

void main() {
  setUpAll(() async {
    final b = TestWidgetsFlutterBinding.ensureInitialized();

    for (final (family, path) in const [
      ('NotoSansTC', 'assets/fonts/NotoSansTC.ttf'),
      ('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(File(path).readAsBytes().then((x) => x.buffer.asByteData()));
      await loader.load();
    }

    final dir = Directory.systemTemp.createTempSync('markcut_scroll_bench');
    _tmpDir = dir.path;
    File(
      '${dir.path}${Platform.pathSeparator}photo.jpg',
    ).writeAsBytesSync(img.encodeJpg(_frame(64, 64, 1), quality: 80));

    final v = b.platformDispatcher.views.first;
    v.physicalSize = const Size(1170, 2532); // iPhone 14
    v.devicePixelRatio = 3.0;

    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => dir.path,
    );
    for (final ch in const [
      'com.llfbandit.record/messages',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }

    // 40 個「會動的」GIF，直式橫式方形混著（瀑布流照原始比例排）。
    // 240~320 這個尺寸接近 App 自己做出來的 GIF
    final gifDir = Directory('${dir.path}${Platform.pathSeparator}gifs')
      ..createSync(recursive: true);
    for (var i = 0; i < _kGifs; i++) {
      final (w, h) = switch (i % 3) {
        0 => (240, 320),
        1 => (280, 280),
        _ => (320, 240),
      };
      final enc = img.GifEncoder(numColors: 64, samplingFactor: 30);
      for (var f = 0; f < 4; f++) {
        enc.addFrame(_frame(w, h, i * 4 + f), duration: 8);
      }
      final bytes = enc.finish()!;
      File(
        '${gifDir.path}${Platform.pathSeparator}gif_$i.gif',
      ).writeAsBytesSync(bytes);
    }

    // 30 份草稿封面：720 高的 JPEG（跟編輯器實際存的一樣）
    _covers = [
      for (var i = 0; i < 6; i++)
        base64Encode(
          img.encodeJpg(
            i % 3 == 0 ? _frame(1280, 720, i) : _frame(405, 720, i),
            quality: 80,
          ),
        ),
    ];
  });

  setUp(_seed);

  testWidgets('個人中心：上下捲動每一格的成本', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: const LightPage(child: ProfileScreen()),
      ),
    );
    await _settle(t);
    final rows = await _scrollBench(t, 'ProfileScreen');
    // ignore: avoid_print
    print(
      '\n=== 個人中心 捲動 bench '
      '（$_kPresets 範本 / $_kDrafts 草稿 / $_kGifs GIF）===\n'
      '${rows.join('\n')}\n',
    );
    await _settle(t, 5);
  }, skip: !_bench);

  // A/B：同一頁但一組範本都沒有（只有「＋」磚，畫不到 WatermarkLayer）。
  // 跟上一支的 paint 相減＝兩塊範本磚每一格要花的錢
  testWidgets('個人中心：沒有範本磚時的成本（對照組）', (t) async {
    _seed(presets: 0);
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: const LightPage(child: ProfileScreen()),
      ),
    );
    await _settle(t);
    final rows = await _scrollBench(t, 'ProfileScreen(0 presets)');
    // ignore: avoid_print
    print('\n=== 個人中心 捲動 bench（0 範本＝對照組）===\n${rows.join('\n')}\n');
    await _settle(t, 5);
  }, skip: !_bench);

  testWidgets('我的 GIF：瀑布流捲動每一格的成本', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: const LightPage(child: GifsScreen()),
      ),
    );
    await _settle(t, 40);
    final rows = await _scrollBench(t, 'GifsScreen');
    // ignore: avoid_print
    print('\n=== 我的 GIF 捲動 bench（$_kGifs 個動圖）===\n${rows.join('\n')}\n');
    await _settle(t, 5);
  }, skip: !_bench);

  testWidgets('草稿夾：瀑布流捲動每一格的成本', (t) async {
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        debugShowCheckedModeBanner: false,
        home: const LightPage(child: DraftsScreen()),
      ),
    );
    await _settle(t, 40);
    final rows = await _scrollBench(t, 'DraftsScreen');
    // ignore: avoid_print
    print('\n=== 草稿夾 捲動 bench（$_kDrafts 份草稿）===\n${rows.join('\n')}\n');
    await _settle(t, 5);
  }, skip: !_bench);
}
