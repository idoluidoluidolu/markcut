// 個人中心改版截圖工具（不是回歸測試）：三個分頁、查看全部、批次刪除、
// 長按小選單、容量與清理。
//
// 用真的佈景、真的字體（NotoSansTC＋Material Icons）、iPhone 14 視窗
//（390×844、DPR 3、安全區 47/34）；草稿、封面、轉檔暫存、GIF 都是暫存
// 目錄裡真的檔案，容量是真的算出來的：
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
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/presets_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/screens/storage_screen.dart';
import 'package:markcut/services/blob_store.dart';
import 'package:markcut/services/draft_assets.dart';
import 'package:markcut/services/draft_store.dart';
import 'package:markcut/services/work_files.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/gif_image.dart';

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

const _palette = [
  [Color(0xFF2B5876), Color(0xFF4E4376)],
  [Color(0xFFDA4453), Color(0xFF89216B)],
  [Color(0xFF136A8A), Color(0xFF267871)],
  [Color(0xFFF7971E), Color(0xFFFFD200)],
  [Color(0xFF3A1C71), Color(0xFFD76D77)],
  [Color(0xFF00467F), Color(0xFFA5CC82)],
];

/// 一張看得出是哪份的封面（漸層）
Future<String> _cover(int i, double aspect) async {
  const h = 640.0;
  final w = (h * aspect).roundToDouble();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(w, h), _palette[i % 6]),
  );
  final im = await rec.endRecording().toImage(w.toInt(), h.toInt());
  final png = await im.toByteData(format: ui.ImageByteFormat.png);
  im.dispose();
  return base64Encode(png!.buffer.asUint8List());
}

/// 一個兩格的 GIF（漸層，第二格換色），[w]×[h]
List<int> _gif(int i, int w, int h) {
  img.Image frame(int seed) {
    final im = img.Image(width: w, height: h);
    final a = _palette[seed % 6][0];
    final b = _palette[seed % 6][1];
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final t = (x / w + y / h) / 2;
        im.setPixelRgb(
          x,
          y,
          ((1 - t) * (a.r * 255) + t * (b.r * 255)).round(),
          ((1 - t) * (a.g * 255) + t * (b.g * 255)).round(),
          ((1 - t) * (a.b * 255) + t * (b.b * 255)).round(),
        );
      }
    }
    return im;
  }

  final enc = img.GifEncoder(numColors: 64, samplingFactor: 20);
  enc.addFrame(frame(i), duration: 40);
  enc.addFrame(frame(i + 1), duration: 40);
  return enc.finish()!;
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
      for (var i = 1; i <= 4; i++) 'wm_presets_seeded_v$i': true,
      'wm_presets_v1': [
        for (final (i, text) in const [
          '@我的頻道',
          '© STUDIO',
          '小日子',
          'DRAFT',
          '@markcut',
        ].indexed)
          WatermarkPreset(
            name: '範本 $i',
            settings: WatermarkSettings()..text.text = text,
          ).encode(),
      ],
    });
    WorkFiles.resetForTest();
    BlobStore.dirOverride = root;
    WorkFiles.supportDirOverride = root;
    DraftAssets.supportDirOverride = root;
    // 我的 GIF：直、方、橫混著
    final gifs = Directory('${root.path}${sep}gifs')..createSync();
    for (final (i, (w, h)) in const [
      (240, 320),
      (280, 280),
      (320, 200),
      (240, 360),
      (300, 300),
    ].indexed) {
      File('${gifs.path}${sep}gif_$i.gif')
        ..writeAsBytesSync(_gif(i, w, h))
        ..setLastModifiedSync(DateTime(2026, 9, 1 + i));
    }
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

  /// 換一頁來拍：每次一棵新的樹（State 不沿用）
  Future<void> show(WidgetTester t, Widget page) async {
    await t.pumpWidget(const SizedBox());
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
          home: LightPage(child: page),
        ),
      ),
    );
    // 真的檔案 I/O：假時間裡每一步都要讓真的事件迴圈跑一下、再 pump
    //（實機一次掃完是幾百毫秒的事）
    await pumpFrames(t, 40);
  }

  /// 批次刪除時「刪掉能省多少」要等容量算完才標得出來
  Future<void> waitSizes(WidgetTester t) async {
    for (var i = 0; i < 400; i++) {
      if (find.textContaining(' MB').evaluate().length > 1) break;
      await pumpFrames(t, 1);
    }
    await pumpFrames(t, 8);
  }

  testWidgets('個人中心改版 → 各頁截圖', (t) async {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);
    await seed(t);

    // 個人中心：三個分頁
    await show(t, const ProfileScreen());
    await shoot(t, 'profile_drafts');
    await t.tap(find.byKey(const ValueKey('profile-tab-1')));
    await pumpFrames(t, 12);
    await shoot(t, 'profile_gifs');
    // GIF 分頁右上角的批次刪除：勾兩個
    await t.tap(find.byKey(const ValueKey('profile-batch')));
    await pumpFrames(t, 4);
    await t.tap(find.byType(GifImage).at(0), warnIfMissed: false);
    await pumpFrames(t, 2);
    await t.tap(find.byType(GifImage).at(1), warnIfMissed: false);
    await pumpFrames(t, 10);
    await shoot(t, 'profile_gifs_batch');
    await t.tap(find.text('取消'));
    await pumpFrames(t, 6);
    await t.tap(find.byKey(const ValueKey('profile-tab-2')));
    await pumpFrames(t, 12);
    await shoot(t, 'profile_presets');
    await t.tap(find.byKey(const ValueKey('profile-tab-0')));
    await pumpFrames(t, 12);
    await t.longPress(find.byType(Image).first);
    await pumpFrames(t, 10);
    await shoot(t, 'profile_menu');

    // 草稿的查看全部：平常、批次刪除（選兩份）、長按小選單
    await show(t, const DraftsScreen());
    await shoot(t, 'drafts_all');
    await t.tap(find.text('批次刪除'));
    await waitSizes(t);
    final tiles = find.byType(Image);
    await t.tap(tiles.at(0), warnIfMissed: false);
    await pumpFrames(t, 2);
    await t.tap(tiles.at(1), warnIfMissed: false);
    await pumpFrames(t, 12);
    await shoot(t, 'drafts_batch');
    await t.tap(find.text('取消'));
    await pumpFrames(t, 10);
    await t.longPress(find.byType(Image).at(1));
    await pumpFrames(t, 10);
    await shoot(t, 'drafts_menu');

    // 我的 GIF：從容量與清理點進來＝一進來就是批次刪除，選兩個
    await show(t, const GifsScreen(batch: true));
    final gifTiles = find.byType(GestureDetector).evaluate().where(
      (e) => (e.widget.key is ValueKey<String>) &&
          ((e.widget.key! as ValueKey<String>).value.startsWith('gif-')),
    );
    for (final e in gifTiles.take(2).toList()) {
      await t.tap(find.byWidget(e.widget), warnIfMissed: false);
      await pumpFrames(t, 2);
    }
    await pumpFrames(t, 10);
    await shoot(t, 'gifs_batch');

    // 範本：長按小選單（改名／刪除）
    await show(t, const PresetsScreen());
    await t.longPress(find.byKey(const ValueKey('preset-範本 1')));
    await pumpFrames(t, 10);
    await shoot(t, 'presets_menu');

    // 容量與清理
    await show(
      t,
      StorageScreen(
        openDrafts: () async {},
        openGifs: () async {},
        openPresets: () async {},
      ),
    );
    for (var i = 0;
        i < 400 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++) {
      await pumpFrames(t, 1);
    }
    await pumpFrames(t, 8);
    await shoot(t, 'storage');

    await t.pumpWidget(const SizedBox());
    BlobStore.dirOverride = null;
    BlobStore.resetForTest();
    WorkFiles.supportDirOverride = null;
    DraftAssets.supportDirOverride = null;
  });
}
