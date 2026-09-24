// 草稿夾截圖工具（不是回歸測試）：佔用空間卡、選取模式的「刪掉能省多少」。
//
// 用真的佈景、真的字體（NotoSansTC＋Material Icons）、iPhone 14 視窗
//（390×844、DPR 3、安全區 47/34）；草稿、封面、轉檔暫存都是暫存目錄裡
// 真的檔案，容量是真的算出來的：
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/drafts_shot_tool.dart
//
// 沒設環境變數時整支略過。檔名沒有 _test 結尾，整批 flutter test 也不會撿它。
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/draft_assets.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/theme.dart';

final _shotKey = GlobalKey();

String? _materialIconsPath() {
  final candidates = <String>[];
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    candidates.add(
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    );
  }
  final exe = Platform.resolvedExecutable.replaceAll(
    String.fromCharCode(92),
    '/',
  );
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

/// 一個指定大小的檔（只寫最後一個位元組，不用真的寫滿）
void _sized(String path, int bytes) {
  final f = File(path)..createSync(recursive: true);
  final raf = f.openSync(mode: FileMode.write);
  raf.setPositionSync(bytes - 1);
  raf.writeByteSync(0);
  raf.closeSync();
}

/// 一張看得出是哪份的封面（漸層＋編號）
Future<String> _cover(int i, double aspect) async {
  const h = 640.0;
  final w = (h * aspect).roundToDouble();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final colors = [
    [const Color(0xFF2B5876), const Color(0xFF4E4376)],
    [const Color(0xFFDA4453), const Color(0xFF89216B)],
    [const Color(0xFF136A8A), const Color(0xFF267871)],
    [const Color(0xFFF7971E), const Color(0xFFFFD200)],
    [const Color(0xFF3A1C71), const Color(0xFFD76D77)],
    [const Color(0xFF00467F), const Color(0xFFA5CC82)],
  ][i % 6];
  c.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(w, h), colors),
  );
  final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return base64Encode(png!.buffer.asUint8List());
}

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '截圖工具，要給輸出資料夾才會跑');
    return;
  }

  late Directory root;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Directory(out).createSync(recursive: true);
    for (final path in const [
      'assets/fonts/NotoSansTC.ttf',
      'assets/fonts/NotoSansTC-Bold.ttf',
    ]) {
      final loader = FontLoader('NotoSansTC')
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
    final icons = _materialIconsPath();
    expect(icons, isNotNull, reason: '找不到 materialicons-regular.otf');
    final il = FontLoader('MaterialIcons')
      ..addFont(File(icons!).readAsBytes().then((b) => b.buffer.asByteData()));
    await il.load();
    final base = Directory(
      '${Directory.current.path}${Platform.pathSeparator}build'
      '${Platform.pathSeparator}drafts_shot',
    )..createSync(recursive: true);
    root = base.createTempSync('run_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });

  // 種的轉檔暫存一次就是 1GB 多（真的佔磁碟），拍完一定要清掉
  tearDownAll(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> seed(WidgetTester t) async {
    final sep = Platform.pathSeparator;
    final wf = '${root.path}${sep}workfiles';
    const mb = 1024 * 1024;
    // 六份草稿：兩份共用同一支素材，一份是舊版（沒有檔案清單）
    final works = <String, String>{};
    final sizes = [180, 95, 240, 60, 130, 75];
    for (var i = 0; i < 6; i++) {
      final w = '$wf${sep}wh$i.mp4';
      _sized(w, sizes[i] * mb);
      works['/photos/clip$i.mov#hdr6'] = w;
    }
    _sized('$wf${sep}wh_orphan.mp4', 310 * mb); // 沒有草稿在用
    works['/photos/gone.mov#hdr6'] = '$wf${sep}wh_orphan.mp4';
    SharedPreferences.setMockInitialValues({
      'workFiles.v4': jsonEncode({
        for (final e in works.entries) e.key: {'work': e.value, 'at': 1},
      }),
    });
    WorkFiles.resetForTest();
    BlobStore.dirOverride = root;
    WorkFiles.supportDirOverride = root;
    DraftAssets.supportDirOverride = root;
    await t.runAsync(() async {
      for (var i = 0; i < 6; i++) {
        final aspect = i == 3 ? 16 / 9 : 9 / 16;
        await DraftStore.save(
          'd$i',
          {
            'savedAt': DateTime(2026, 9, 20 - i).toIso8601String(),
            'sources': [
              {'path': '/photos/clip$i.mov'},
              if (i == 1) {'path': '/photos/clip0.mov'},
            ],
            'clips': [
              {'id': 1},
            ],
            'wm': {'b64': 'A' * (i == 2 ? 3 * mb : 600 * 1024)},
          },
          thumb: await _cover(i, aspect),
          thumbAspect: aspect,
          clipCount: 1,
          refs: i == 5
              ? null
              : {
                  '/photos/clip$i.mov',
                  if (i == 1) '/photos/clip0.mov',
                },
        );
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
  }

  Future<void> pumpFrames(WidgetTester t, int n) async {
    for (var i = 0; i < n; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> shoot(WidgetTester t, String name) async {
    await t.runAsync(() async {
      final b =
          _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await b.toImage(pixelRatio: 3);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      im.dispose();
      File(
        '$out${Platform.pathSeparator}$name.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('草稿夾 → drafts_usage.png／drafts_select.png', (t) async {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);
    await seed(t);
    await t.pumpWidget(
      RepaintBoundary(
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
            Locale.fromSubtags(
              languageCode: 'zh',
              scriptCode: 'Hant',
              countryCode: 'TW',
            ),
          ],
          home: const LightPage(child: DraftsScreen()),
        ),
      ),
    );
    // 真的檔案 I/O：假時間裡每一步都要讓真的事件迴圈跑一下、再 pump
    //（實機一次掃完是幾百毫秒的事）
    var waited = 0;
    for (;
        waited < 400 &&
            (find.textContaining('正在計算').evaluate().isNotEmpty ||
                find.byType(CircularProgressIndicator).evaluate().isNotEmpty);
        waited++) {
      await pumpFrames(t, 1);
    }
    // ignore: avoid_print
    print('容量算完用了 $waited 輪');
    await pumpFrames(t, 20);
    await shoot(t, 'drafts_usage');

    await t.tap(find.text('選取'));
    await pumpFrames(t, 4);
    final tiles = find.byType(Image);
    await t.tap(tiles.at(0), warnIfMissed: false);
    await pumpFrames(t, 2);
    await t.tap(tiles.at(1), warnIfMissed: false);
    await pumpFrames(t, 12);
    await shoot(t, 'drafts_select');

    BlobStore.dirOverride = null;
    BlobStore.resetForTest();
    WorkFiles.supportDirOverride = null;
    DraftAssets.supportDirOverride = null;
  });
}
