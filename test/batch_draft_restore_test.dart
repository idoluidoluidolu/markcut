// 批次浮水印的草稿續作與離開保護（稽核 #3、#9、#10、#12、#15）：
//
// - 續作時少了一個檔案，單張覆寫不能位移到別張（以前用索引當鍵：
//   [a,b,c] 少了 a，b 的覆寫落到 c，再存一次草稿就永久化）
// - 續作含覆寫的草稿、什麼都沒動就返回：不問「這批還沒匯出」
//   （以前把「有覆寫」直接當成改過，這時按「捨棄」整份草稿就沒了）
// - 面板拿得到畫布比例（九宮格「靠邊」才夾得準）
// - 匯出成功＝草稿清掉、之後沒再動離開不問（跟 GIF 同一條規矩）
// - 影片方向修正：預覽跟匯出共用 reconcileVideoDims
// - 選完才講的提醒（#14）：首頁進場、批次中途「＋」、拼圖截斷同一句
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
import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/services/video_picker.dart' show pickCountHint;
import 'package:markcut/services/video_processor.dart' show CanvasRatio;
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/watermark_panel.dart';

Future<Uint8List> _png(Color c, int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = c,
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

/// 縮圖、讀檔都是真的 I/O，pump 一輪不夠
Future<void> _settle(WidgetTester t, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

late Directory _dir;

/// 三張真的照片檔（草稿續作靠路徑）
Future<List<String>> _files(
  WidgetTester t, {
  int n = 3,
  int w = 120,
  int h = 90,
}) async {
  final out = <String>[];
  await t.runAsync(() async {
    for (var i = 0; i < n; i++) {
      final p = '${_dir.path}${Platform.pathSeparator}p$i.png';
      File(
        p,
      ).writeAsBytesSync(await _png(Color(0xFF203040 + i * 0x102030), w, h));
      out.add(p);
    }
  });
  return out;
}

/// 從一個假的首頁把批次頁 push 出去：離開保護要能真的 pop 回來
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
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await _settle(t);
}

/// 返回鍵：走 PopScope（跟實機按返回鍵同一條路）
Future<void> _back(WidgetTester t) async {
  unawaited(t.state<NavigatorState>(find.byType(Navigator)).maybePop());
  await t.pumpAndSettle();
}

/// 單張覆寫的標記：縮圖左上角那顆 8×8、外距 3 的琥珀小點（面板的調色盤
/// 也有琥珀色的圓，尺寸不同）。回傳它們的中心 x
List<double> _dotXs(WidgetTester t) => [
  for (final e
      in find
          .byWidgetPredicate(
            (w) =>
                w is Container &&
                w.constraints ==
                    const BoxConstraints.tightFor(width: 8, height: 8) &&
                w.margin == const EdgeInsets.all(3) &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).shape == BoxShape.circle &&
                (w.decoration as BoxDecoration).color == kSelect,
          )
          .evaluate())
    t.getCenter(find.byWidget(e.widget)).dx,
];

Map<String, dynamic> _ov(double x) =>
    (WatermarkSettings()..text.x = x).toJson();

/// 覆寫 JSON 裡那一筆文字浮水印的 x（toJson 存的是 texts 清單）
double _ovX(dynamic json) =>
    (((json as Map)['texts'] as List).first as Map)['x'] as double;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _dir = Directory.systemTemp.createTempSync('batch_restore_');
  });

  tearDown(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('batchRestoreFor：舊草稿的索引鍵換成路徑、少了檔案也對得上；新草稿的路徑鍵對到現在的路徑', () {
    final draft = {
      'files': ['/t/a.jpg', '/t/b.jpg', '/t/c.jpg'],
      'settings': WatermarkSettings().toJson(),
      'ratio': 0,
      'overrides': {'1': _ov(0.2), '2': _ov(0.3), '7': _ov(0.9)},
    };
    // a 不見了；b、c 現在讀的是複本
    final r = batchRestoreFor(draft, [null, '/copy/b.jpg', '/copy/c.jpg']);
    expect(r['files'], ['/copy/b.jpg', '/copy/c.jpg']);
    final ov = r['overrides'] as Map;
    expect(ov.keys.toSet(), {'/copy/b.jpg', '/copy/c.jpg'});
    expect(_ovX(ov['/copy/b.jpg']), 0.2, reason: 'b 的覆寫要跟著 b 走');
    expect(_ovX(ov['/copy/c.jpg']), 0.3);
    expect(r['settings'], draft['settings']);

    final byPath = {
      ...draft,
      'overrides': {'/t/c.jpg': _ov(0.4)},
    };
    final r2 = batchRestoreFor(byPath, ['/t/a.jpg', null, '/t/c.jpg']);
    expect(r2['files'], ['/t/a.jpg', '/t/c.jpg']);
    expect(_ovX((r2['overrides'] as Map)['/t/c.jpg']), 0.4);
  });

  test('pickCountHint：略過的、超上限的、數量偏多的各講各的，沒事就不出聲', () {
    expect(pickCountHint(count: 5, unit: '部影片', soft: 30), isNull);
    expect(
      pickCountHint(count: 30, unit: '部影片', soft: 30),
      isNull,
      reason: '剛好不算多',
    );
    expect(
      pickCountHint(count: 31, unit: '部影片', soft: 30),
      '選了 31 部影片，處理會比較久',
      reason: '批次中途的「＋」跟首頁進場要同一句',
    );
    expect(
      pickCountHint(skipped: 2, count: 201, unit: '張照片', soft: 200),
      '已略過 2 個非影片檔案；選了 201 張照片，處理會比較久',
    );
    expect(pickCountHint(dropped: 6, cap: 30), '最多 30 張，已略過 6 張');
    expect(pickCountHint(dropped: 6), isNull, reason: '沒有上限就沒有這句');
  });

  test('reconcileVideoDims：方向以看到的畫面為準，像素數照 probe；正方形、缺資料都不亂動', () {
    expect(reconcileVideoDims((1920, 1080), (1080, 1920)), (
      1080,
      1920,
    ), reason: 'probe 讀歪：對調');
    expect(reconcileVideoDims((1920, 1080), (640, 360)), (1920, 1080));
    expect(reconcileVideoDims((1080, 1080), (360, 640)), (
      1080,
      1080,
    ), reason: '正方形沒有方向');
    expect(reconcileVideoDims((1920, 1080), null), (1920, 1080));
    expect(reconcileVideoDims((1920, 1080), (0, 0)), (1920, 1080));
    expect(reconcileVideoDims((0, 0), (360, 640)), (360, 640));
  });

  testWidgets('續作少了第一個檔案：b 的單張覆寫落在 b（第一格）、不是 c', (t) async {
    final paths = await _files(t);
    final draft = {
      'files': paths,
      'settings': WatermarkSettings().toJson(),
      'ratio': 0,
      'overrides': {'1': _ov(0.2)},
    };
    // 個人頁那條路：a 不見了，濾掉之後把整理過的草稿交給頁面
    await t.pumpWidget(
      MaterialApp(
        home: BatchWatermarkScreen(
          files: [XFile(paths[1]), XFile(paths[2])],
          restore: batchRestoreFor(draft, [null, paths[1], paths[2]]),
        ),
      ),
    );
    await _settle(t);
    final xs = _dotXs(t);
    expect(xs.length, 1, reason: '只有 b 有覆寫');
    // 縮圖列：左邊留白 10、每格 56 寬、間距 6——第一格在 10~66、第二格從 72 起
    expect(xs.single, lessThan(66), reason: '琥珀點要在第一格（b），不是第二格（c）');
  });

  testWidgets('舊草稿直接餵給頁面（索引鍵）：照草稿自己的檔案清單對回路徑，一樣不位移', (t) async {
    final paths = await _files(t);
    await t.pumpWidget(
      MaterialApp(
        home: BatchWatermarkScreen(
          files: [XFile(paths[1]), XFile(paths[2])],
          restore: {
            'files': paths,
            'settings': WatermarkSettings().toJson(),
            'overrides': {'1': _ov(0.2)},
          },
        ),
      ),
    );
    await _settle(t);
    final xs = _dotXs(t);
    expect(xs.length, 1);
    expect(xs.single, lessThan(66));
  });

  testWidgets('續作含覆寫的草稿、沒動就返回：不問、草稿留著；動了才問', (t) async {
    final paths = await _files(t);
    final draft = {
      'files': paths,
      'settings': WatermarkSettings().toJson(),
      'ratio': CanvasRatio.r1_1.index,
      'overrides': {paths[1]: _ov(0.2)},
      'savedAt': '2026-01-01T00:00:00',
    };
    SharedPreferences.setMockInitialValues({kBatchDraftKey: jsonEncode(draft)});
    await _pumpFromHome(
      t,
      BatchWatermarkScreen(
        files: [for (final p in paths) XFile(p)],
        restore: draft,
      ),
    );
    expect(_dotXs(t).length, 1);
    await _back(t);
    expect(find.text('這批還沒匯出'), findsNothing, reason: '什麼都沒動不該問');
    expect(find.text('首頁'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kBatchDraftKey), isNotNull, reason: '草稿要原封留著');

    // 再進去、動一下（換畫布比例）：這次要問
    await t.tap(find.text('首頁'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _settle(t);
    await t.tap(find.text('1:1'));
    await t.pumpAndSettle();
    await t.tap(find.text('16:9'));
    await t.pumpAndSettle();
    await _back(t);
    expect(find.text('這批還沒匯出'), findsOneWidget);
    await t.tap(find.text('繼續編輯'));
    await t.pumpAndSettle();
  });

  testWidgets('面板拿得到畫布比例：跟著素材、換了比例跟著換', (t) async {
    final paths = await _files(t, n: 1, w: 90, h: 160);
    await t.pumpWidget(
      MaterialApp(home: BatchWatermarkScreen(files: [XFile(paths[0])])),
    );
    await _settle(t);
    double? panelAspect() =>
        t.widget<WatermarkPanel>(find.byType(WatermarkPanel)).canvasAspect;
    expect(panelAspect(), closeTo(90 / 160, 1e-6), reason: '直式素材＝直式畫布');
    await t.tap(find.text('原始'));
    await t.pumpAndSettle();
    await t.tap(find.text('16:9'));
    await t.pumpAndSettle();
    expect(panelAspect(), closeTo(16 / 9, 1e-6));
  });

  testWidgets('拒絕相簿權限：提示失敗、保留草稿，不顯示匯出完成', (t) async {
    var saved = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const gal = MethodChannel('gal');
    messenger.setMockMethodCallHandler(gal, (call) async {
      if (call.method == 'hasAccess' || call.method == 'requestAccess') {
        return false;
      }
      if (call.method == 'putImageBytes') saved++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(gal, null));

    final paths = await _files(t, n: 1);
    final draft = jsonEncode({
      'files': paths,
      'settings': WatermarkSettings().toJson(),
    });
    SharedPreferences.setMockInitialValues({kBatchDraftKey: draft});
    await _pumpFromHome(
      t,
      BatchWatermarkScreen(files: [for (final p in paths) XFile(p)]),
    );
    await t.tap(find.text('匯出'));
    await t.pumpAndSettle();
    await t.tap(find.text('PNG 無損'));
    await t.pump();
    for (var i = 0; i < 150; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 100));
      if (find.textContaining('沒有相簿存取權限').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('完成 0 個，1 個失敗'), findsOneWidget);
    expect(find.textContaining('請到系統設定開啟'), findsOneWidget);
    expect(find.text('匯出完成'), findsNothing);
    expect(saved, 0);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kBatchDraftKey), draft);
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
  });

  testWidgets('匯出成功：草稿清掉、之後沒再動返回不問', (t) async {
    // 相簿由 gal 套件寫入，接住它的通道
    var saved = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const gal = MethodChannel('gal');
    messenger.setMockMethodCallHandler(gal, (call) async {
      switch (call.method) {
        case 'hasAccess':
        case 'requestAccess':
          return true;
        case 'putImageBytes':
          saved++;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(gal, null));

    final paths = await _files(t, n: 2);
    SharedPreferences.setMockInitialValues({
      kBatchDraftKey: jsonEncode({
        'files': paths,
        'settings': WatermarkSettings().toJson(),
      }),
    });
    await _pumpFromHome(
      t,
      BatchWatermarkScreen(files: [for (final p in paths) XFile(p)]),
    );
    await t.tap(find.text('匯出'));
    await t.pumpAndSettle();
    await t.tap(find.text('PNG 無損'));
    await t.pump();
    for (var i = 0; i < 150 && find.text('匯出完成').evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('匯出完成'), findsOneWidget);
    expect(saved, 2, reason: '兩張都要走到存相簿');
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(kBatchDraftKey),
      isNull,
      reason: '匯出過的草稿要清掉，個人頁不該再有「未完成的批次」',
    );

    await t.tap(find.text('繼續編輯'));
    await t.pumpAndSettle();
    await _back(t);
    expect(find.text('這批還沒匯出'), findsNothing);
    expect(find.text('首頁'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
