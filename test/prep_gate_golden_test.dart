// 進場讀取畫面的快照（golden）。
//
// 產生／更新圖片：
//   flutter test --update-goldens test/prep_gate_golden_test.dart
// 圖片會寫在 test/goldens/ 底下。
//
// 這一頁是使用者進 App 之後看到的第一個畫面，文案與版面被改動時
// golden 對不上就會失敗——改動一定是有意識的
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/theme.dart';
import 'package:markcut/widgets/prep_gate_view.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 真的把 App 的字體載進來，不然中文全是空白框
    for (final (family, path) in const [
      ('NotoSansTC', 'assets/fonts/NotoSansTC.ttf'),
      ('NotoSansTC', 'assets/fonts/NotoSansTC-Bold.ttf'),
    ]) {
      final loader = FontLoader(family)
        ..addFont(File(path).readAsBytes().then((b) => b.buffer.asByteData()));
      await loader.load();
    }
  });

  Widget wrap(Widget child) => MaterialApp(
    theme: buildStudioTheme(),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      appBar: AppBar(title: const Text('影片編輯')),
      body: child,
    ),
  );

  testWidgets('讀取畫面：備素材中', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    await tester.pumpWidget(
      wrap(const PrepGateView(done: 1, total: 3)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(PrepGateView),
      matchesGoldenFile('goldens/prep_gate.png'),
    );
  });

  testWidgets('讀取畫面：還不知道有幾支素材', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 500));
    await tester.pumpWidget(
      wrap(const PrepGateView(done: 0, total: 0, ready: false)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await expectLater(
      find.byType(PrepGateView),
      matchesGoldenFile('goldens/prep_gate_loading.png'),
    );
  });
}
