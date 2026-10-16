// 拼圖載入速度（使用者 10-16 回報「照片拼圖載入速度慢」）：
//
// iOS 上拼圖的照片改走原生 ImageIO 縮圖（markcut/photo 的 preview，照片
// 編輯器本來就在用的那條），不在 Flutter 裡整張 12～48MP 解開再縮；
// 而且同時排三張（原生那邊一張張縮、這邊解 PNG 跟下一張重疊），放進格子
// 的順序照挑選的順序。按「裁切」也直接拿原生縮好的 PNG，不再解開重編。
//
// 照片路徑故意指到不存在的檔：走回 Flutter 自己解檔的老路的話一張都
// 解不出來，測試就會紅
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/collage_screen.dart';
import 'package:markcut/screens/crop_screen.dart';
import 'package:markcut/services/collage_image_budget.dart';

const _channel = MethodChannel('markcut/photo');

Future<Uint8List> _png(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = const Color(0xFF3060A0),
  );
  final img = await rec.endRecording().toImage(w, h);
  final d = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return d!.buffer.asUint8List();
}

CollageLayoutPeek _peek(WidgetTester t) =>
    t.state(find.byType(CollageScreen)) as CollageLayoutPeek;

/// 圖片解碼是真的非同步工作：一邊 runAsync 一邊 pump，等到 [ready]
Future<void> _until(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: '等太久了');
}

/// 讓已經能跑的都跑一跑（不保證任何東西完成）
Future<void> _churn(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Uint8List> pngs;
  late List<String> calls;
  late List<int> sides;
  late List<Completer<void>> gates;

  /// 原生端：記下每一次 preview（路徑、要的大小），等那一張的閘門開了才回
  void mockNative() {
    t() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    t().setMockMethodCallHandler(_channel, (call) async {
      if (call.method != 'preview') return null;
      final args = (call.arguments as Map).cast<String, Object?>();
      final path = args['path']! as String;
      final i = int.parse(RegExp(r'p(\d+)\.heic$').firstMatch(path)!.group(1)!);
      calls.add(path);
      sides.add(args['maxSide']! as int);
      await gates[i].future;
      return {'bytes': pngs[i], 'w': 4000 + i, 'h': 3000, 'hdr': false};
    });
    addTearDown(() => t().setMockMethodCallHandler(_channel, null));
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    sides = [];
  });
  // 原生路只在 iOS 開（EditorPhoto.native 看 defaultTargetPlatform）
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  testWidgets('iOS：照片走原生縮圖、同時排三張、照挑選的順序放進格子', (t) async {
    pngs = (await t.runAsync(
      () => Future.wait([for (var i = 0; i < 5; i++) _png(100 + i * 10, 80)]),
    ))!;
    gates = List.generate(5, (_) => Completer<void>());
    mockNative();
    await t.pumpWidget(
      MaterialApp(
        home: CollageScreen(
          photos: [
            for (var i = 0; i < 5; i++)
              XFile('/nowhere/p$i.heic', name: 'p$i.heic'),
          ],
        ),
      ),
    );
    await _churn(t);
    // 三張同時在排；第四張要等前面交回一張
    expect(calls, [for (var i = 0; i < 3; i++) '/nowhere/p$i.heic']);
    // 後面的先回來：還是要等第 0 張，順序不能亂、也不多開
    gates[2].complete();
    gates[1].complete();
    await _churn(t);
    expect(calls, hasLength(3));
    expect(_peek(t).images, isEmpty);
    gates[0].complete();
    for (final g in gates.skip(3)) {
      g.complete();
    }
    await _until(
      t,
      () =>
          _peek(t).images.length == 5 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    expect(calls, [for (var i = 0; i < 5; i++) '/nowhere/p$i.heic']);
    expect(sides.toSet(), {kCollagePreviewMaxSide}, reason: '照張數分級的預覽大小');
    // 放進來的是原生縮好的那幾張，順序照挑的
    expect(
      [for (final img in _peek(t).images) img!.width],
      [100, 110, 120, 130, 140],
    );
    expect(_peek(t).layout.order.take(5), [0, 1, 2, 3, 4]);
    expect(t.takeException(), isNull);
  }, variant: ios);

  testWidgets('iOS：原生讀不出來的那張略過，其他照放', (t) async {
    pngs = (await t.runAsync(
      () => Future.wait([for (var i = 0; i < 3; i++) _png(60 + i * 10, 40)]),
    ))!;
    gates = List.generate(3, (_) => Completer<void>()..complete());
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method != 'preview') return null;
      final path = (call.arguments as Map)['path'] as String;
      calls.add(path);
      if (path.endsWith('p1.heic')) return null; // 讀不出來
      final i = int.parse(RegExp(r'p(\d+)\.heic$').firstMatch(path)!.group(1)!);
      return {'bytes': pngs[i], 'w': 900, 'h': 600, 'hdr': false};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    await t.pumpWidget(
      MaterialApp(
        home: CollageScreen(
          photos: [
            for (var i = 0; i < 3; i++)
              XFile('/nowhere/p$i.heic', name: 'p$i.heic'),
          ],
        ),
      ),
    );
    await _until(
      t,
      () =>
          calls.length == 3 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await _churn(t);
    expect([for (final img in _peek(t).images) img!.width], [60, 80]);
    expect(t.takeException(), isNull);
  }, variant: ios);

  testWidgets('iOS：按裁切直接拿原生縮好的那張 PNG（不在這邊解開再編一次）', (t) async {
    pngs = (await t.runAsync(
      () => Future.wait([_png(123, 77), _png(90, 60)]),
    ))!;
    gates = List.generate(2, (_) => Completer<void>()..complete());
    mockNative();
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        home: CollageScreen(
          photos: [
            for (var i = 0; i < 2; i++)
              XFile('/nowhere/p$i.heic', name: 'p$i.heic'),
          ],
        ),
      ),
    );
    await _until(
      t,
      () =>
          _peek(t).images.length == 2 &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    final cells = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_CellPainter',
    );
    await t.tap(cells.first);
    await t.pump();
    final crop = find.byKey(const ValueKey('collage-crop-photo'));
    expect(crop, findsOneWidget);
    calls.clear();
    sides.clear();
    await t.tap(crop);
    await _until(t, () => find.byType(CropScreen).evaluate().isNotEmpty);
    expect(calls, ['/nowhere/p0.heic']);
    expect(sides, [kCollagePreviewMaxSide]);
    expect(
      t.widget<CropScreen>(find.byType(CropScreen)).bytes,
      pngs[0],
      reason: '原生縮好的那張直接拿去裁',
    );
    Navigator.of(t.element(find.byType(CropScreen))).pop();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  }, variant: ios);
}
