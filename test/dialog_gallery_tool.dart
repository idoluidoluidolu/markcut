// 對話框／底部表單／提示 全家福產圖工具（不是回歸測試）。
//
// 用真的佈景（buildStudioTheme／LightPage）、真的字體（NotoSansTC＋
// Material Icons）、真的 iPhone 14 視窗（390×844、DPR 3、安全區 47/34），
// 把 App 裡每一種 modal 真的打開來拍成 PNG，給設計檢視用。
//
//   MARKCUT_DIALOG_GALLERY_OUT=<資料夾> flutter test --no-pub test/dialog_gallery_tool.dart
//
// 沒設環境變數時整支略過。檔名沒有 _test 結尾，整批 flutter test 也不會撿它。
//
// 能走真的操作路徑的（按真的按鈕）就走真的；只有靠原生外掛或檔案才打得開的
// （匯出進度、多選影片、斗內感謝…），照 lib/ 裡的程式碼逐字重建，檔名標 recon-。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/batch_watermark_screen.dart';
import 'package:markcut/screens/feedback_screen.dart';
import 'package:markcut/screens/home_screen.dart';
import 'package:markcut/screens/photo_editor_screen.dart';
import 'package:markcut/screens/presets_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/screens/video_editor_screen.dart';
import 'package:markcut/screens/watermark_studio_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_image.dart';
import 'package:markcut/widgets/kaomoji_sheet.dart';
import 'package:markcut/widgets/sticker_picker.dart';
import 'package:markcut/widgets/watermark_layer.dart';

late final String _out;
late final Directory _tmp;
late final String _png8; // 8×8 PNG 檔
final _shotKey = GlobalKey();
final _written = <String>[];

/// 8×8 PNG（測試自己寫出來，不依賴任何外部檔案）
const _pngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGO4Y2ODFTEM'
    'LQkAXrdVAdmuFfUAAAAASUVORK5CYII=';

// ===== 環境 =====

/// 真的 iPhone 14：邏輯 390×844、dpr 3，安全區（47／34）用實體像素給
void _iphone14(WidgetTester t) {
  t.view.devicePixelRatio = 3.0;
  t.view.physicalSize = const Size(1170, 2532);
  t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
  t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
  addTearDown(t.view.reset);
}

/// 真的非同步（SharedPreferences、圖片解碼）要 runAsync 才推得動
Future<void> _settle(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// 跟 main.dart 一樣的 MaterialApp（佈景、語系），外面包一層
/// RepaintBoundary 拍整個畫面（對話框、表單、提示都畫在 Navigator 的
/// overlay 上，抓 App 根節點才拍得到）
Widget _app(Widget home, {bool light = false}) => RepaintBoundary(
  key: _shotKey,
  child: MaterialApp(
    theme: buildStudioTheme(),
    debugShowCheckedModeBanner: false,
    locale: const Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: const [
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant', countryCode: 'TW'),
      Locale('zh', 'TW'),
      Locale('zh'),
      Locale('en'),
    ],
    home: light ? LightPage(child: home) : home,
  ),
);

Future<void> _shot(WidgetTester t, String name) async {
  await t.runAsync(() async {
    final b =
        _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final im = await b.toImage(pixelRatio: 3);
    final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    File('$_out${Platform.pathSeparator}$name.png').writeAsBytesSync(
      bytes!.buffer.asUint8List(),
    );
  });
  _written.add(name);
}

BuildContext _ctx(WidgetTester t) => t.element(find.byType(Scaffold).first);

NavigatorState _nav(WidgetTester t) =>
    t.state<NavigatorState>(find.byType(Navigator).first);

Future<void> _close(WidgetTester t, [int n = 8]) async {
  _nav(t).pop();
  await _settle(t, n);
}

/// 測試結束前把 showHint（2.4 秒）、顏文字提示（1.2 秒）的計時器跑完
Future<void> _drain(WidgetTester t) => t.pump(const Duration(seconds: 3));

Future<Uint8List> _solidPng(Color c, int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = c,
  );
  final im = await rec.endRecording().toImage(w, h);
  final d = await im.toByteData(format: ui.ImageByteFormat.png);
  im.dispose();
  return d!.buffer.asUint8List();
}

String? _materialIconsPath() {
  final candidates = <String>[];
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    candidates.add(
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  final exe = Platform.resolvedExecutable.replaceAll('\\', '/');
  final i = exe.indexOf('/bin/cache/');
  if (i >= 0) {
    candidates.add(
      '${exe.substring(0, i)}'
      '/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

void _seedPresets() {
  final daily = WatermarkPreset(
    name: '日常',
    settings: WatermarkSettings()..text.text = '@我的浮水印',
  );
  final work = WatermarkPreset(
    name: '接案',
    settings: WatermarkSettings()..text.text = '© STUDIO',
  );
  SharedPreferences.setMockInitialValues({
    'wm_presets_v1': [daily.encode(), work.encode()],
    'wm_presets_seeded_v1': true,
    'wm_presets_seeded_v2': true,
    'wm_presets_seeded_v3': true,
    'wm_presets_seeded_v4': true,
  });
}

// ===== 影片編輯器（深色主場）=====

/// 兩段圖片片段在第一軌（排序、刪整軌才有東西可排／可刪），外加一支
/// 「有檔案、沒片段」的影片素材（匯出頁的畫質依它的位元率挑，才有「推薦」）
Map<String, dynamic> _videoDraft({
  bool withVideoSource = true,

  /// 兩段之間留 4 秒空隙（長按空白處的選單要有空白可按）
  bool gap = false,
}) => {
  'savedAt': '2026-08-14T00:00:00.000',
  'sources': [
    MediaSource(
      path: _png8,
      name: 'a.png',
      kind: ClipKind.image,
      w: 400,
      h: 400,
      duration: 3600,
    ).toJson(),
    MediaSource(
      path: _png8,
      name: 'b.png',
      kind: ClipKind.image,
      w: 400,
      h: 400,
      duration: 3600,
    ).toJson(),
    if (withVideoSource)
      MediaSource(
        path: '${_tmp.path}${Platform.pathSeparator}clip.mp4',
        name: 'clip.mp4',
        kind: ClipKind.video,
        w: 1920,
        h: 1080,
        duration: 10,
      ).toJson(),
  ],
  'clips': [
    TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 0,
      trimEnd: 4,
      offset: 0,
      track: 0,
    ).toJson(),
    TimelineClip(
      id: 2,
      sourceIndex: 1,
      trimStart: 0,
      trimEnd: 3,
      offset: gap ? 8 : 4,
      track: 0,
    ).toJson(),
  ],
  'speed': 1.0,
  'ratio': 0,
  'res': 0,
  'quality': 0,
  'qualityAuto': true,
  'wmStart': 0.0,
  'extraTracks': 0,
};

Future<void> _pumpVideo(WidgetTester t, {Map<String, dynamic>? draft}) async {
  _iphone14(t);
  await t.pumpWidget(_app(VideoEditorScreen(draft: draft ?? _videoDraft())));
  await _settle(t, 30);
  expect(find.text('加素材'), findsOneWidget, reason: '影片編輯器沒開起來');
}

Finder _clip(int id) => find.byKey(ValueKey('clip$id'));

/// 時間軸上編號最大的那一段（剛加進去的）
Finder _newestClip(WidgetTester t) {
  var best = -1;
  for (final e in find.byWidgetPredicate((w) {
    final k = w.key;
    return k is ValueKey<String> && k.value.startsWith('clip');
  }).evaluate()) {
    final n = int.tryParse((e.widget.key! as ValueKey<String>).value.substring(4));
    if (n != null && n > best) best = n;
  }
  expect(best, greaterThan(0), reason: '時間軸上找不到片段');
  return _clip(best);
}

Future<void> _selectClip(WidgetTester t, Finder f) async {
  await t.tapAt(t.getRect(f).center);
  await _settle(t, 6);
}

// ===== 照片編輯器 =====

Future<void> _pumpPhoto(WidgetTester t) async {
  late Uint8List bytes;
  await t.runAsync(() async {
    bytes = await _solidPng(const Color(0xFF6A7A8A), 900, 600);
  });
  _iphone14(t);
  await t.pumpWidget(
    _app(
      PhotoEditorScreen(
        photo: XFile.fromData(bytes, name: 'p.png', mimeType: 'image/png'),
      ),
    ),
  );
  await _settle(t, 25);
}

// ===== 批次 =====

Future<void> _pumpBatch(WidgetTester t) async {
  late Uint8List bytes;
  await t.runAsync(() async {
    bytes = await _solidPng(const Color(0xFF204060), 64, 64);
  });
  _iphone14(t);
  await t.pumpWidget(
    _app(
      BatchWatermarkScreen(
        files: [
          XFile.fromData(bytes, name: 'a.png', mimeType: 'image/png'),
          XFile.fromData(bytes, name: 'b.png', mimeType: 'image/png'),
        ],
      ),
    ),
  );
  await _settle(t, 25);
  expect(find.text('匯出'), findsOneWidget, reason: '批次頁沒開起來');
}

// ===== 工作室 =====

Future<void> _pumpStudio(WidgetTester t) async {
  _seedPresets();
  _iphone14(t);
  await t.pumpWidget(_app(const WatermarkStudioScreen()));
  await _settle(t, 25);
}

// ===== 淺色頁 =====

Future<void> _pumpLight(WidgetTester t, Widget page) async {
  _iphone14(t);
  await t.pumpWidget(_app(page, light: true));
  await _settle(t, 25);
}

void main() {
  final out = Platform.environment['MARKCUT_DIALOG_GALLERY_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_DIALOG_GALLERY_OUT', () {}, skip: '產圖工具，要給輸出資料夾才會跑');
    return;
  }
  _out = out;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    Directory(_out).createSync(recursive: true);

    // 真的把 App 的字體載進來，不然中文全是空白框
    for (final (family, path) in const [
      ('NotoSansTC', 'assets/fonts/NotoSansTC.ttf'),
      ('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
    // Material Icons 也要載：測試環境預設沒有，圖示會變成空方框
    final icons = _materialIconsPath();
    expect(icons, isNotNull, reason: '找不到 materialicons-regular.otf');
    final il = FontLoader('MaterialIcons')
      ..addFont(File(icons!).readAsBytes().then((b) => b.buffer.asByteData()));
    await il.load();

    _tmp = Directory.systemTemp.createTempSync('markcut_dialog_gallery');
    _png8 = '${_tmp.path}${Platform.pathSeparator}t.png';
    File(_png8).writeAsBytesSync(base64Decode(_pngB64));
    // 10 秒、10 MB → 8 Mbps：匯出頁量位元率用，內容不重要
    File(
      '${_tmp.path}${Platform.pathSeparator}clip.mp4',
    ).writeAsBytesSync(List<int>.filled(10 * 1024 * 1024, 0));
    // 「我的 GIF」要一個真的會動的 GIF
    final gifDir = Directory('${_tmp.path}${Platform.pathSeparator}gifs')
      ..createSync(recursive: true);
    final enc = img.GifEncoder(numColors: 8);
    for (var f = 0; f < 2; f++) {
      final im = img.Image(width: 120, height: 90);
      for (var y = 0; y < 90; y++) {
        for (var x = 0; x < 120; x++) {
          im.setPixelRgb(x, y, x * 2, y * 2, f * 200);
        }
      }
      enc.addFrame(im, duration: 8);
    }
    File(
      '${gifDir.path}${Platform.pathSeparator}demo.gif',
    ).writeAsBytesSync(enc.finish()!);

    for (final ch in const [
      'com.llfbandit.record/messages',
      'dev.fluttercommunity.plus/wakelock',
    ]) {
      b.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(ch),
        (_) async => null,
      );
    }
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _tmp.path,
    );
    b.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('flutter.arthenica.com/ffmpeg_kit_event'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  tearDownAll(() {
    File('$_out${Platform.pathSeparator}_written.txt').writeAsStringSync(
      _written.join('\n'),
    );
  });

  // ---------- 影片編輯器 ----------

  testWidgets('ve: 離開對話框 → 捨棄 → showConfirm', (t) async {
    await _pumpVideo(t);
    unawaited(_nav(t).maybePop());
    await _settle(t, 10);
    expect(find.text('保留草稿'), findsOneWidget);
    await _shot(t, '12-ve-leave-dialog');
    await t.tap(find.text('捨棄'));
    await _settle(t, 10);
    expect(find.text('捨棄這份草稿？'), findsOneWidget);
    await _shot(t, '02-confirm-dark-discard-draft');
    await _close(t);
    await _drain(t);
  });

  testWidgets('ve: 加素材 → 文字 → 文字樣式表 / 片段選單', (t) async {
    await _pumpVideo(t);
    await t.tap(find.text('加素材'));
    await _settle(t, 10);
    expect(find.text('加在畫面上'), findsOneWidget);
    await _shot(t, '13-ve-add-media-sheet');
    await t.tap(find.text('文字'));
    await _settle(t, 10);
    expect(find.text('輸入文字'), findsOneWidget);
    await _shot(t, '14-ve-text-input-dialog');
    await t.enterText(find.byType(TextField), '週末小旅行');
    await t.tap(find.text('加入'));
    await _settle(t, 15);
    final tc = _newestClip(t);
    await t.longPressAt(t.getRect(tc).center);
    await _settle(t, 10);
    expect(find.text('編輯文字'), findsOneWidget, reason: '片段長按選單沒開');
    await _shot(t, '15-ve-clip-context-menu');
    await t.tap(find.text('編輯文字'));
    await _settle(t, 15);
    expect(find.byType(BottomSheet), findsOneWidget);
    await _shot(t, '16-ve-text-style-sheet');
    await _close(t);
    await _drain(t);
  });

  testWidgets('ve: 長按空白處選單 → 刪除整軌 showConfirm', (t) async {
    await _pumpVideo(t, draft: _videoDraft(gap: true));
    // 兩段之間的空隙（第一軌 4～8 秒）
    final r1 = t.getRect(_clip(1));
    final r2 = t.getRect(_clip(2));
    await t.longPressAt(Offset((r1.right + r2.left) / 2, r1.center.dy));
    await _settle(t, 10);
    expect(find.text('銜接這一軌'), findsOneWidget, reason: '空白處長按選單沒開');
    await _shot(t, '17-ve-empty-context-menu');
    await t.tap(find.text('刪除整軌'));
    await _settle(t, 10);
    expect(find.text('刪除第 1 軌？'), findsOneWidget);
    await _shot(t, '01-confirm-dark-delete-track');
    await _close(t);
    await _drain(t);
  });

  testWidgets('ve: 縮放 / 效果（_optSheet）/ 排序 / 圖片片段表', (t) async {
    await _pumpVideo(t);
    await _selectClip(t, _clip(1));
    // 工具列是橫向捲的，右邊那幾顆在 390 寬的畫面外
    await t.ensureVisible(find.text('縮放'));
    await _settle(t, 4);
    await t.tap(find.text('縮放'));
    await _settle(t, 12);
    expect(find.byType(BottomSheet), findsOneWidget);
    await _shot(t, '19-ve-scale-sheet');
    await _close(t);

    await t.ensureVisible(find.text('效果'));
    await _settle(t, 4);
    await t.tap(find.text('效果'));
    await _settle(t, 12);
    expect(find.byType(BottomSheet), findsOneWidget);
    await _shot(t, '20-ve-fade-sheet');
    await _close(t);

    await t.ensureVisible(find.text('排序'));
    await _settle(t, 4);
    await t.tap(find.text('排序'));
    await _settle(t, 15);
    expect(find.text('調整片段順序'), findsOneWidget);
    await _shot(t, '21-ve-reorder-sheet');
    await _close(t);

    // 選中的片段再點一下 → 圖片調整表（排序表關掉後選取還在，
    // 第一下可能就直接開了；沒開才再點一下）
    await _selectClip(t, _clip(1));
    if (find.byType(BottomSheet).evaluate().isEmpty) {
      await _selectClip(t, _clip(1));
    }
    await _settle(t, 10);
    expect(find.byType(BottomSheet), findsOneWidget, reason: '圖片片段表沒開');
    expect(find.text('圖片'), findsWidgets);
    await _shot(t, '28-ve-image-clip-sheet');
    await _close(t);
    await _drain(t);
  });

  testWidgets('ve: 播放診斷表（長按標題）', (t) async {
    await _pumpVideo(t, draft: _videoDraft(withVideoSource: false));
    final title = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(GestureDetector),
    );
    await t.longPress(title.first);
    await _settle(t, 15);
    expect(find.text('出報告'), findsOneWidget, reason: '診斷表沒開');
    await _shot(t, '22-ve-diag-sheet');
    await _close(t);
    await _drain(t);
  });

  testWidgets('ve: 匯出頁四個選單', (t) async {
    await _pumpVideo(t);
    await t.tap(find.text('匯出').last);
    await _settle(t, 15);
    for (final (label, file) in const [
      ('畫面比例', '23-ve-ratio-dialog'),
      ('畫質', '24-ve-quality-dialog'),
      ('順暢度', '25-ve-fps-dialog'),
      ('解析度', '26-ve-resolution-dialog'),
    ]) {
      await t.tap(find.text(label));
      await _settle(t, 10);
      expect(find.byType(AlertDialog), findsOneWidget, reason: '$label 沒開');
      await _shot(t, file);
      await _close(t);
    }
    await _drain(t);
  });

  testWidgets('ve: 多張圖片串成影片（秒數對話框）', (t) async {
    _iphone14(t);
    await t.pumpWidget(_app(VideoEditorScreen(photoPaths: [_png8, _png8, _png8])));
    await _settle(t, 30);
    expect(find.text('3 張圖片串成影片'), findsOneWidget);
    await _shot(t, '18-ve-slide-seconds-dialog');
    await _drain(t);
  });

  testWidgets('ve: 馬賽克樣式表', (t) async {
    await _pumpVideo(t);
    await t.tap(find.text('加素材'));
    await _settle(t, 10);
    await t.tap(find.text('馬賽克'));
    await _settle(t, 15);
    final mc = _newestClip(t);
    await t.longPressAt(t.getRect(mc).center);
    await _settle(t, 10);
    expect(find.text('調整馬賽克'), findsOneWidget, reason: '馬賽克片段選單沒開');
    await t.tap(find.text('調整馬賽克'));
    await _settle(t, 15);
    expect(find.text('馬賽克樣式'), findsOneWidget);
    await _shot(t, '27-ve-mosaic-style-sheet');
    await _close(t);
    await _drain(t);
  });

  testWidgets('ve: 共用視窗（通知後、挑色、提示）＋ 重建的進度／多選視窗', (t) async {
    SharedPreferences.setMockInitialValues({
      'recent_colors_v1': ['4293467747', '4281176254'],
    });
    await _pumpVideo(t);
    final ctx = _ctx(t);

    unawaited(askAfterExport(ctx, '已存到相簿'));
    await _settle(t, 10);
    expect(find.text('匯出完成'), findsOneWidget);
    await _shot(t, '05-after-export-dark-plain');
    await _close(t);

    unawaited(pickColor(ctx, const Color(0xFF42A5F5)));
    await _settle(t, 12);
    expect(find.text('色相'), findsOneWidget);
    await _shot(t, '09-pick-color-dark');
    await _close(t);

    showHint(ctx, '已複製到剪貼簿');
    // 剛插進 overlay 的提示要先建出來（第一幀），淡入才會在下一幀跑完
    await t.pump();
    await t.pump(const Duration(milliseconds: 260));
    await _shot(t, '10-hint-dark');
    await _drain(t);
    showHint(ctx, '這個檔案無法播放，換一個試試', error: true);
    // 剛插進 overlay 的提示要先建出來（第一幀），淡入才會在下一幀跑完
    await t.pump();
    await t.pump(const Duration(milliseconds: 260));
    await _shot(t, '11-hint-dark-error');
    await _drain(t);

    // 逐字重建：video_editor_screen.dart 9808 匯出進度
    final progress = ValueNotifier<double>(0.42);
    var cancelRequested = false;
    unawaited(
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (context, setDialog) => AlertDialog(
              title: const Text('匯出中…'),
              content: ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, v, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: v > 0 ? v : null),
                    const SizedBox(height: 12),
                    Text('${(v * 100).toStringAsFixed(0)} %'),
                    const SizedBox(height: 4),
                    const Text(
                      '剩下約 0:37',
                      style: TextStyle(fontSize: 12, color: kTextDim),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: cancelRequested
                      ? null
                      : () => setDialog(() => cancelRequested = true),
                  child: Text(cancelRequested ? '取消中…' : '取消'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(t, 10);
    await _shot(t, '29-recon-ve-export-progress');
    await _close(t);

    // 逐字重建：video_editor_screen.dart 14203 倒轉進度
    final rev = ValueNotifier<double>(0.63);
    unawaited(
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('正在倒轉…'),
            content: ValueListenableBuilder<double>(
              valueListenable: rev,
              builder: (context, v, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: v > 0 ? v : null),
                  const SizedBox(height: 12),
                  Text('${(v * 100).toStringAsFixed(0)} %'),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () {}, child: const Text('取消')),
            ],
          ),
        ),
      ),
    );
    await _settle(t, 10);
    await _shot(t, '30-recon-ve-reverse-progress');
    await _close(t);

    // 逐字重建：video_editor_screen.dart 4690 加入 N 部影片
    unawaited(
      showDialog<bool>(
        context: ctx,
        builder: (context) => AlertDialog(
          title: const Text('加入 3 部影片'),
          contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
          content: SizedBox(
            width: 270,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                optionRow(
                  context: context,
                  title: '接在同一軌',
                  subtitle: '照選取順序頭尾相接，變成一段長影片',
                  selected: false,
                  first: true,
                  onTap: () => Navigator.pop(context, true),
                ),
                optionRow(
                  context: context,
                  title: '各自一軌',
                  subtitle: '每個影片開一個新軌道',
                  selected: false,
                  onTap: () => Navigator.pop(context, false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(t, 10);
    await _shot(t, '31-recon-ve-ask-same-track');
    await _close(t);

    // 逐字重建：video_editor_screen.dart 4764 音樂來源
    unawaited(
      showModalBottomSheet<bool>(
        context: ctx,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              ListTile(
                leading: const Icon(Icons.library_music_outlined, color: kAmber),
                title: const Text('音樂檔案'),
                onTap: () => Navigator.pop(context, false),
              ),
              ListTile(
                leading: const Icon(Icons.movie_outlined, color: kAmber),
                title: const Text('從影片提取聲音'),
                subtitle: const Text(
                  '只取影片的音軌，不會加入畫面',
                  style: TextStyle(fontSize: 11.5, color: kTextDim),
                ),
                onTap: () => Navigator.pop(context, true),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    await _settle(t, 12);
    await _shot(t, '32-recon-ve-audio-source-sheet');
    await _close(t);

    // 顏文字表（共用元件）＋ 點一顆的「已複製」提示
    unawaited(showKaomojiSheet(ctx));
    await _settle(t, 15);
    expect(find.text('顏文字（點一個複製）'), findsOneWidget);
    await _shot(t, '33-kaomoji-sheet');
    final chip = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(InkWell),
    );
    await t.tap(chip.first);
    await t.pump(const Duration(milliseconds: 120));
    await _settle(t, 3);
    expect(find.text('已複製'), findsOneWidget);
    await _shot(t, '34-kaomoji-copied-overlay');
    await _drain(t);
    await _close(t);

    // 貼圖挑選（共用元件）
    unawaited(pickSticker(ctx));
    await _settle(t, 15);
    expect(find.text('貼圖'), findsWidgets);
    await _shot(t, '35-sticker-picker-sheet');
    await _close(t);
    await _drain(t);
  });

  // ---------- 工作室 ----------

  testWidgets('studio: 範本挑選表、showNotice、離開三選一', (t) async {
    await _pumpStudio(t);
    await t.tap(find.text('範本').first);
    await _settle(t, 15);
    expect(find.text('選擇範本'), findsOneWidget);
    await _shot(t, '36-wm-preset-picker-sheet');
    await _close(t);

    final ctx = _ctx(t);
    unawaited(
      showNotice(ctx, title: '已存成範本', message: '之後在「範本」分頁或個人頁都找得到'),
    );
    await _settle(t, 10);
    await _shot(t, '03-notice-dark-preset-saved');
    await _close(t);

    unawaited(
      showLeaveChoice(
        ctx,
        title: '還沒存成範本',
        message: '離開後這個設計就會消失',
        keepLabel: '存成範本',
        discardLabel: '放棄離開',
      ),
    );
    await _settle(t, 10);
    await _shot(t, '08-leave-choice-dark-studio');
    await _close(t);
    await _drain(t);
  });

  // ---------- 照片編輯器 ----------

  testWidgets('photo: 畫面比例、浮水印組表、馬賽克樣式表、共用視窗、進度重建', (t) async {
    await _pumpPhoto(t);
    final ctx = _ctx(t);

    await t.tap(find.text('原始').first);
    await _settle(t, 10);
    expect(find.text('畫面比例'), findsOneWidget);
    await _shot(t, '37-photo-ratio-dialog');
    await _close(t);

    unawaited(
      showLeaveChoice(
        ctx,
        title: '還沒輸出',
        message: '可以在個人頁面的「草稿」繼續未完成的編輯',
        keepLabel: '保留草稿',
        discardLabel: '捨棄',
      ),
    );
    await _settle(t, 10);
    await _shot(t, '07-leave-choice-dark-photo');
    await _close(t);

    unawaited(
      askAfterExport(ctx, '已存到相簿', note: '這個裝置不支援 JPEG，已改存 PNG'),
    );
    await _settle(t, 10);
    await _shot(t, '04-after-export-dark-with-note');
    await _close(t);

    // 逐字重建：photo_editor_screen.dart 1739（collage_screen.dart 892 同一份）
    unawaited(
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => const PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text('匯出中…'),
            content: SizedBox(
              height: 48,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
      ),
    );
    await _settle(t, 8);
    await _shot(t, '40-recon-photo-export-progress');
    await _close(t);

    // 馬賽克：面板是分頁的，先點導覽列「馬賽克」那格，
    // 再按那一區的 ＋（加一塊）→ 那一塊的「調整樣式」
    await t.tap(find.text('馬賽克').first);
    await _settle(t, 8);
    await t.tap(find.byTooltip('加一塊馬賽克').first, warnIfMissed: false);
    await _settle(t, 10);
    await t.tap(find.byTooltip('調整樣式').first, warnIfMissed: false);
    await _settle(t, 12);
    expect(find.text('馬賽克樣式'), findsOneWidget, reason: '照片的馬賽克樣式表沒開');
    await _shot(t, '39-photo-mosaic-style-sheet');
    await _close(t);

    // 浮水印組：導覽列「文字」→ 捲到「浮水印」加號列 → 編輯面板（0.72 高）
    await t.tap(find.text('文字').first);
    await _settle(t, 8);
    final addLabel = find.descendant(
      of: find.byType(SingleChildScrollView),
      matching: find.text('浮水印'),
    );
    await t.ensureVisible(addLabel.first);
    await _settle(t, 4);
    final addRow = find.ancestor(of: addLabel, matching: find.byType(InkWell));
    await t.tap(addRow.first, warnIfMissed: false);
    await _settle(t, 15);
    expect(find.text('刪除這組'), findsOneWidget, reason: '浮水印組編輯面板沒開');
    await _shot(t, '38-photo-extra-wm-sheet');
    await _close(t);
    await _drain(t);
  });

  // ---------- 批次 ----------

  testWidgets('batch: 輸出格式、畫面比例、縮圖長按表、進度重建', (t) async {
    await _pumpBatch(t);
    await t.tap(find.text('匯出'));
    await _settle(t, 10);
    expect(find.text('輸出到相簿'), findsOneWidget);
    await _shot(t, '06-photo-format-dark');
    await _close(t);

    await t.tap(find.byIcon(Icons.aspect_ratio).first);
    await _settle(t, 10);
    expect(find.text('畫面比例'), findsOneWidget);
    await _shot(t, '41-batch-ratio-dialog');
    await _close(t);

    // 縮圖列的長按選單
    final cands = find.byWidgetPredicate(
      (w) => w is InkWell && w.onLongPress != null,
    );
    var opened = false;
    for (var i = 0; i < cands.evaluate().length && !opened; i++) {
      await t.longPress(cands.at(i), warnIfMissed: false);
      await _settle(t, 10);
      opened = find.text('從批次移除').evaluate().isNotEmpty;
      if (!opened && find.byType(BottomSheet).evaluate().isNotEmpty) {
        await _close(t);
      }
    }
    expect(opened, isTrue, reason: '縮圖長按選單沒開');
    await _shot(t, '42-batch-thumb-sheet');
    await _close(t);

    // 逐字重建：batch_watermark_screen.dart 775 批次進度
    final ctx = _ctx(t);
    final overall = ValueNotifier<double>(0.4);
    final label = ValueNotifier<String>('第 2 / 5 個');
    unawaited(
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('批次匯出中…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<double>(
                  valueListenable: overall,
                  builder: (context, v, _) => LinearProgressIndicator(value: v),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<String>(
                  valueListenable: label,
                  builder: (context, s, _) => Text(
                    s,
                    style: const TextStyle(fontSize: 12, color: kTextDim),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () {}, child: const Text('取消')),
            ],
          ),
        ),
      ),
    );
    await _settle(t, 8);
    await _shot(t, '43-recon-batch-progress');
    await _close(t);

    // 逐字重建：gif_screen.dart 725 製作 GIF 進度
    final gp = ValueNotifier<double>(0.8);
    var cancelRequested = false;
    unawaited(
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (context, setDialog) => AlertDialog(
              title: const Text('製作 GIF 中…'),
              content: ValueListenableBuilder<double>(
                valueListenable: gp,
                builder: (context, v, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LinearProgressIndicator(value: v > 0 ? v : null),
                    const SizedBox(height: 12),
                    Text('${(v * 100).toStringAsFixed(0)} %'),
                    const SizedBox(height: 4),
                    const Text(
                      '剩下約 0:04',
                      style: TextStyle(fontSize: 12, color: kTextDim),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: cancelRequested
                      ? null
                      : () => setDialog(() => cancelRequested = true),
                  child: Text(cancelRequested ? '取消中…' : '取消'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(t, 8);
    await _shot(t, '44-recon-gif-progress');
    await _close(t);
    await _drain(t);
  });

  // ---------- 首頁（淺色）----------

  testWidgets('home: 首頁四顆入口 ＋ 重建的多選影片視窗', (t) async {
    // 「加入浮水印」的選單沒了：四顆入口（浮水印／照片拼圖／GIF／
    // 影片編輯）直接在首頁上，各自進功能
    await _pumpLight(t, const HomeScreen());
    expect(find.text('照片拼圖'), findsOneWidget);
    await _shot(t, '45-home-four-entries');

    // 逐字重建：home_screen.dart _askMultiVideo 選了 N 部影片
    final ctx = _ctx(t);
    unawaited(
      showDialog<bool>(
        context: ctx,
        builder: (context) => AlertDialog(
          title: const Text('選了 3 部影片'),
          contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 16),
          content: SizedBox(
            width: 270,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                optionRow(
                  context: context,
                  title: '剪成一支影片',
                  subtitle: '照選取順序接起來',
                  selected: false,
                  first: true,
                  onTap: () => Navigator.pop(context, true),
                ),
                optionRow(
                  context: context,
                  title: '統一上浮水印',
                  subtitle: '快速套用同一組浮水印',
                  selected: false,
                  onTap: () => Navigator.pop(context, false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await _settle(t, 10);
    await _shot(t, '46-recon-home-ask-multi-video');
    await _close(t);
    await _drain(t);
  });

  // ---------- 個人中心（淺色）----------

  testWidgets('profile: 意見回饋、長按範本刪除 showConfirm、提示、斗內感謝重建', (t) async {
    _seedPresets();
    await _pumpLight(t, const ProfileScreen());
    final ctx = _ctx(t);

    unawaited(showFeedbackDialog(ctx));
    await _settle(t, 12);
    expect(find.text('聯絡我'), findsOneWidget);
    await _shot(t, '47-feedback-dialog');
    await _close(t);

    await t.longPress(find.byType(WatermarkLayer).first, warnIfMissed: false);
    await _settle(t, 10);
    expect(find.textContaining('刪除範本「'), findsOneWidget, reason: '長按範本磚沒有跳確認');
    await _shot(t, '56-confirm-light-profile-delete-preset');
    await _close(t);

    showHint(ctx, '已改名為「日常」');
    // 剛插進 overlay 的提示要先建出來（第一幀），淡入才會在下一幀跑完
    await t.pump();
    await t.pump(const Duration(milliseconds: 260));
    await _shot(t, '53-hint-light');
    await _drain(t);
    showHint(ctx, '已有同名範本，換個名字', error: true);
    // 剛插進 overlay 的提示要先建出來（第一幀），淡入才會在下一幀跑完
    await t.pump();
    await t.pump(const Duration(milliseconds: 260));
    await _shot(t, '54-hint-light-error');
    await _drain(t);

    // 逐字重建：donate_screen.dart 90 感謝視窗（斗內頁也是淺色頁）
    unawaited(
      showDialog<void>(
        context: ctx,
        builder: (context) => AlertDialog(
          title: const Text('謝謝你的加菜金！🙏'),
          content: const Text('每一份心意都會變成我們繼續改進的動力 💪'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('好'),
            ),
          ],
        ),
      ),
    );
    await _settle(t, 10);
    await _shot(t, '55-recon-donate-thanks');
    await _close(t);
    await _drain(t);
  });

  testWidgets('gifs: 來源選單、放大檢視', (t) async {
    await _pumpLight(t, const GifsScreen());
    await t.tap(find.byType(FloatingActionButton));
    await _settle(t, 10);
    expect(find.text('從檔案選'), findsOneWidget);
    await _shot(t, '51-gif-source-sheet');
    await _close(t);

    expect(find.byType(GifImage), findsWidgets, reason: '「我的 GIF」沒讀到範例');
    await t.tap(find.byType(GifImage).first, warnIfMissed: false);
    await _settle(t, 12);
    await _shot(t, '52-gif-lightbox');
    await _close(t);
    await _drain(t);
  });

  testWidgets('presets: 長按選單、刪除 showConfirm', (t) async {
    _seedPresets();
    await _pumpLight(t, const PresetsScreen());
    await t.longPress(find.byType(WatermarkLayer).first, warnIfMissed: false);
    await _settle(t, 10);
    expect(find.text('改名'), findsOneWidget, reason: '範本長按選單沒開');
    await _shot(t, '49-presets-actions-sheet');
    await t.tap(find.text('刪除'));
    await _settle(t, 10);
    expect(find.textContaining('刪除範本「'), findsOneWidget);
    await _shot(t, '48-confirm-light-delete-preset');
    await _close(t);
    await _drain(t);
  });

  // 改名對話框的輸入框有 autofocus：用 Navigator.pop 硬關會在測試環境
  // 踩到 _FocusInheritedScope 的 _dependents 斷言，關掉要走真的「取消」，
  // 而且放在最後一支，不讓它影響別的畫面
  testWidgets('presets: 改名對話框', (t) async {
    _seedPresets();
    await _pumpLight(t, const PresetsScreen());
    await t.longPress(find.byType(WatermarkLayer).first, warnIfMissed: false);
    await _settle(t, 10);
    await t.tap(find.text('改名'));
    await _settle(t, 15);
    expect(find.text('範本改名'), findsOneWidget);
    await _shot(t, '50-presets-rename-dialog');
    FocusManager.instance.primaryFocus?.unfocus();
    await _settle(t, 5);
    await t.tap(find.text('取消'));
    await _settle(t, 15);
    await _drain(t);
  });
}
