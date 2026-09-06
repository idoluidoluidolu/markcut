// 個人中心／範本總覽截圖工具（不是回歸測試）。
//
// 用真的佈景（buildStudioTheme／LightPage）、真的字體（NotoSansTC＋
// Material Icons）、真的 iPhone 14 視窗（390×844、DPR 3、安全區 47/34），
// 種兩份草稿、三個 GIF、兩個範本，把個人中心現在的樣子拍成 PNG：
//
//   MARKCUT_SHOT_OUT=<資料夾> flutter test --no-pub test/profile_shot_tool.dart
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

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/presets_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';

final _shotKey = GlobalKey();
late final String _tmp;

/// 最小的合法 GIF（1×1 透明）
const _gifBytes = <int>[
  71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 0, 0, 0, //
  255, 255, 255, 33, 249, 4, 1, 10, 0, 1, 0, 44, 0, 0, 0, 0, //
  1, 0, 1, 0, 0, 2, 2, 76, 1, 0, 59,
];

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

/// 範本存 prefs、GIF 是文件目錄底下真的檔案、草稿是 project_data_* 的內容鍵
void _seed({int presets = 2, int gifs = 3, int drafts = 2}) {
  final data = <String, Object>{
    'wm_presets_seeded_v1': true,
    if (presets > 0)
      'wm_presets_v1': <String>[
        for (var i = 0; i < presets; i++)
          WatermarkPreset(
            name: '範本 $i',
            settings: WatermarkSettings()..text.text = '@我的浮水印',
          ).encode(),
      ],
  };
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

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  if (out == null || out.isEmpty) {
    test('略過：沒設 MARKCUT_SHOT_OUT', () {}, skip: '截圖工具，要給輸出資料夾才會跑');
    return;
  }

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

    _tmp = Directory.systemTemp.createTempSync('markcut_profile_shot').path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => _tmp,
        );
  });

  /// 共用：拍一張整頁
  Future<void> shoot(WidgetTester t, String name, Widget home) async {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: LightPage(child: home),
        ),
      ),
    );
    for (var i = 0; i < 15; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump(const Duration(milliseconds: 40));
    }
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

  testWidgets('範本總覽 → presets.png', (t) async {
    _seed(presets: 4);
    await shoot(t, 'presets', PresetsScreen(key: UniqueKey()));
  });

  testWidgets('個人中心 → profile.png', (t) async {
    _seed();
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    t.view.padding = const FakeViewPadding(top: 141, bottom: 102);
    t.view.viewPadding = const FakeViewPadding(top: 141, bottom: 102);
    addTearDown(t.view.reset);

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
            Locale('zh', 'TW'),
            Locale('zh'),
            Locale('en'),
          ],
          home: LightPage(child: ProfileScreen(key: UniqueKey())),
        ),
      ),
    );
    // SharedPreferences、GifStore、圖片解碼都是真的非同步
    for (var i = 0; i < 15; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await t.pump(const Duration(milliseconds: 40));
    }
    await t.runAsync(() async {
      final b =
          _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final im = await b.toImage(pixelRatio: 3);
      final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
      im.dispose();
      File(
        '$out${Platform.pathSeparator}profile.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
