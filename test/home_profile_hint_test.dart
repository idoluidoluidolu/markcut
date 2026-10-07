// 首頁的新手教學（使用者從畫布四個方向挑了「甲 聚光燈」，文案指定
// 「草稿、GIF、範本都存在這裡」）：
//   1. 第一次進首頁：整個畫面壓暗，右上角個人中心那一圈亮著，下面一個
//      泡泡寫那句話＋「知道了」
//   2. 點哪裡都收起來、記住看過了；下次進來不再出現
//   3. 點在亮著的那一圈上＝收起來＋打開個人中心
//   4. 教學還在時按到「開始」：只收起教學，不會順手開選單
//   5. 畫面大小改變（轉向）：亮著的那一圈跟著鈕走
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/home_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/theme.dart';
import 'package:markcut/widgets/spotlight_hint.dart';

const _text = '草稿、GIF、範本都存在這裡';
Finder get _hint => find.byType(SpotlightHint);
Finder get _profile => find.byTooltip('個人中心');

late Directory _dir;

class _Spy extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);
}

/// SharedPreferences、量鈕的位置都要真的非同步跑完
Future<void> _settle(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

/// [seen]＝null：不重設 SharedPreferences（接著上一次存下來的）
Future<_Spy> _pump(WidgetTester t, {bool? seen = false}) async {
  if (seen != null) {
    SharedPreferences.setMockInitialValues({
      if (seen) kHomeProfileHintKey: true,
    });
  }
  t.view.devicePixelRatio = 3.0;
  t.view.physicalSize = const Size(1206, 2622);
  t.view.padding = const FakeViewPadding(top: 186, bottom: 102);
  t.view.viewPadding = const FakeViewPadding(top: 186, bottom: 102);
  addTearDown(t.view.reset);
  final spy = _Spy();
  await t.pumpWidget(
    MaterialApp(
      theme: buildStudioTheme(),
      navigatorObservers: [spy],
      home: const LightPage(child: HomeScreen()),
    ),
  );
  await _settle(t);
  return spy;
}

void main() {
  setUpAll(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    _dir = Directory.systemTemp.createTempSync('markcut_hint_');
    b.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => _dir.path,
    );
  });
  tearDownAll(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('第一次進首頁：右上角那一圈亮著，下面寫「草稿、GIF、範本都存在這裡」', (t) async {
    await _pump(t);
    expect(find.text(_text), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
    // 亮著的那一圈＝個人中心那顆鈕
    final target = t.widget<SpotlightHint>(_hint).target;
    expect(target.center.dx, closeTo(t.getCenter(_profile).dx, 0.5));
    expect(target.center.dy, closeTo(t.getCenter(_profile).dy, 0.5));
    // 泡泡在鈕的下面、整個在畫面裡
    final bubble = t.getRect(find.text(_text));
    expect(bubble.top, greaterThan(t.getRect(_profile).bottom));
    expect(bubble.right, lessThanOrEqualTo(t.getSize(_hint).width));
    expect(t.takeException(), isNull);
  });

  testWidgets('點掉就記住：下次進來不再出現', (t) async {
    await _pump(t);
    await t.tap(find.text('知道了'));
    await _settle(t);
    expect(_hint, findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kHomeProfileHintKey), isTrue);
    // 下次進來（同一份設定）
    await t.pumpWidget(const SizedBox());
    await _pump(t, seen: null);
    expect(_hint, findsNothing);
    expect(find.text(_text), findsNothing);
  });

  testWidgets('看過了：首頁本體照舊，沒有教學', (t) async {
    await _pump(t, seen: true);
    expect(_hint, findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('點在亮著的那一圈上：收起來，順手打開個人中心', (t) async {
    final spy = await _pump(t);
    final before = spy.pushed.length;
    await t.tapAt(t.getCenter(_profile));
    await t.pump();
    expect(_hint, findsNothing);
    expect(spy.pushed.length, before + 1, reason: '要打開個人中心');
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(ProfileScreen), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kHomeProfileHintKey), isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('教學還在時按到「開始」：只收起教學，不會順手開選單', (t) async {
    await _pump(t);
    await t.tapAt(t.getCenter(find.byType(FloatingActionButton)));
    await _settle(t);
    expect(_hint, findsNothing);
    expect(find.text('照片拼圖'), findsNothing, reason: '那一下是拿來收教學的');
    await t.tap(find.byType(FloatingActionButton));
    await _settle(t);
    expect(find.text('照片拼圖'), findsOneWidget, reason: '收掉之後「開始」照常');
  });

  testWidgets('畫面大小改變（轉向）：亮著的那一圈跟著鈕走', (t) async {
    await _pump(t);
    t.view.physicalSize = const Size(2622, 1206);
    t.view.padding = const FakeViewPadding(left: 186, right: 186, bottom: 63);
    t.view.viewPadding = const FakeViewPadding(
      left: 186,
      right: 186,
      bottom: 63,
    );
    await _settle(t);
    final target = t.widget<SpotlightHint>(_hint).target;
    expect(target.center.dx, closeTo(t.getCenter(_profile).dx, 0.5));
    expect(target.center.dy, closeTo(t.getCenter(_profile).dy, 0.5));
    expect(t.takeException(), isNull);
  });
}
