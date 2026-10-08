// 字型下載的介面截圖（產圖工具，不是回歸測試）：浮水印面板文字卡的字型
// 選單——還沒下載的字名照原樣、右邊下載圖示；點下去按鈕上轉進度；下載完
// 換過去（真的字型檔、真的字型引擎）。
//
//   MARKCUT_SHOT_OUT=<資料夾> MARKCUT_FONTS_DIR=<markcut-fonts/fonts>
//     flutter test --no-pub test/font_menu_shot_tool.dart
//
// 沒設環境變數時整支略過。網路用假的：照檔名回 MARKCUT_FONTS_DIR 裡的檔，
// 可以卡在一半拍「下載中」
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/font_store.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/watermark_panel.dart';

final _shotKey = GlobalKey();

String? _materialIconsPath() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final exe = Platform.resolvedExecutable.replaceAll(
    String.fromCharCode(92),
    '/',
  );
  final i = exe.indexOf('/bin/cache/');
  for (final c in [
    if (root != null)
      '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
    if (i >= 0)
      '${exe.substring(0, i)}'
          '/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  ]) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

Future<void> _settle(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _load(String family, String path) async {
  final loader = FontLoader(family)
    ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
  await loader.load();
}

void main() {
  final out = Platform.environment['MARKCUT_SHOT_OUT'];
  final dl = Platform.environment['MARKCUT_FONTS_DIR'];
  if (out == null || out.isEmpty || dl == null || dl.isEmpty) {
    test(
      '略過：沒設 MARKCUT_SHOT_OUT／MARKCUT_FONTS_DIR',
      () {},
      skip: '截圖工具，要給輸出資料夾與 markcut-fonts 的 fonts 資料夾才會跑',
    );
    return;
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Directory(out).createSync(recursive: true);
    // 內建字型照 pubspec 的家族名載（選單上每一行都用自己的字型寫字名）
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final entry = RegExp(r'- family: (\w+)\s+fonts:\s+- asset: (\S+)');
    for (final m in entry.allMatches(pubspec)) {
      await _load(m.group(1)!, m.group(2)!);
    }
    await _load('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf');
    final icons = _materialIconsPath();
    expect(icons, isNotNull, reason: '找不到 materialicons-regular.otf');
    await _load('MaterialIcons', icons!);
  });

  Future<void> snap(WidgetTester t, String name) => t.runAsync(() async {
    final b =
        _shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final im = await b.toImage(pixelRatio: 3);
    final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });

  testWidgets('字型選單 → font_menu / font_downloading / font_applied', (t) async {
    t.view.devicePixelRatio = 3.0;
    t.view.physicalSize = const Size(1170, 2532);
    addTearDown(t.view.reset);
    // 假網路：照檔名回真的字型檔；大波浪圓體送到四成先卡住
    final hold = Completer<void>();
    FontStore.instance.debugReset(
      client: () => MockClient.streaming((req, _) async {
        final name = req.url.pathSegments.last;
        final bytes = File('$dl/$name').readAsBytesSync();
        final cut = (bytes.length * 0.4).round();
        Stream<List<int>> body() async* {
          yield bytes.sublist(0, cut);
          await hold.future;
          yield bytes.sublist(cut);
        }

        return http.StreamedResponse(body(), 200);
      }),
    );
    addTearDown(FontStore.instance.debugReset);
    final settings = WatermarkSettings(
      texts: [TextMark(text: '阿明的攝影日記', fontFamily: 'Yozai')],
    );
    await t.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: MaterialApp(
          theme: buildStudioTheme(),
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: SafeArea(
              child: WatermarkPanel(settings: settings, onChanged: () {}),
            ),
          ),
        ),
      ),
    );
    await _settle(t);
    await t.tap(find.text('文字').first);
    await _settle(t, 12);
    final dropdown = find.byType(DropdownButton<String>);
    await t.ensureVisible(dropdown);
    await _settle(t);
    await t.tap(dropdown);
    await _settle(t);
    // 選單往上捲，讓下載的那幾款整行露出來
    await t.drag(find.byType(Scrollable).last, const Offset(0, -150));
    await _settle(t);
    await snap(t, 'font_menu');

    await t.tap(find.text('大波浪圓體').last);
    await _settle(t);
    await snap(t, 'font_downloading');

    hold.complete();
    // 真的檔：背景算雜湊、載進字型引擎都要真的時間
    for (var i = 0; i < 100 && settings.text.fontFamily != 'PopGothic'; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump(const Duration(milliseconds: 40));
    }
    await _settle(t);
    expect(settings.text.fontFamily, 'PopGothic');
    await snap(t, 'font_applied');
  });
}
