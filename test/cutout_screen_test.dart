// 照片去背（首頁「去背 → 照片」）：
//   1. 一進來自動找主體、全部留下；下面一排每個主體一個縮圖
//   2. 點縮圖、點照片上的主體＝留↔不留，跟原生要那幾個的遮罩；上一步退得回來
//   3. 一個都沒留：匯出擋下來
//   4. 修邊：一指在照片上畫＝一筆（保留／擦除照選的）
//   5. 背景：透明／模糊／純色換得過去
//   6. 找不到（通道回 null）、只認得出人（Android 主體模型還沒好）：提示、不炸
//   7. 改過了按返回：問要不要放棄
//   8. 畫圖本身：透明背景只留遮罩；純色墊滿；保留／擦除筆畫照畫
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/cutout_screen.dart';
import 'package:markcut/services/cutout_photo.dart';
import 'package:markcut/widgets/cutout_swatch.dart';

const _cutout = MethodChannel('markcut/cutout');

late Directory _dir;
late String _photoPath;

/// 分析尺寸 100×50：主體 1＝左半、主體 2＝右邊四分之一
const _w = 100, _h = 50;

int _labelAt(int x, int y) => x < 50 ? 1 : (x >= 75 ? 2 : 0);

Uint8List _maskOf(Set<int> ids) {
  final m = Uint8List(_w * _h);
  for (var y = 0; y < _h; y++) {
    for (var x = 0; x < _w; x++) {
      if (ids.contains(_labelAt(x, y))) m[y * _w + x] = 255;
    }
  }
  return m;
}

Map<String, Object?>? _analysis = {};
final _calls = <MethodCall>[];

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

Future<void> _settle(WidgetTester t, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(900, 1800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CutoutScreen(photo: XFile(_photoPath, name: 'p.png')),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await _settle(t, 12);
}

/// 預覽的 painter（私有類別，照欄位名稱讀）
dynamic _painter(WidgetTester t) => t
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .firstWhere((p) => p.runtimeType.toString() == '_CutoutPreviewPainter');

Finder get _avatars =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_SubjectAvatar');

/// 照片在預覽上的框（painter 的 rect）
Rect _photoRect(WidgetTester t) {
  final r = _painter(t).rect as Rect;
  final box = t.getTopLeft(
    find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString() == '_CutoutPreviewPainter',
    ),
  );
  return r.shift(box);
}

List<int> _photoMaskIds() => [
  for (final c in _calls)
    if (c.method == 'photoMask')
      ...((c.arguments as Map)['ids'] as List).cast<int>(),
];

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    _dir = Directory.systemTemp.createTempSync('markcut_cutout_');
    _photoPath = '${_dir.path}${Platform.pathSeparator}p.png';
    File(
      _photoPath,
    ).writeAsBytesSync(await _png(const Color(0xFF808080), 1000, 500));
  });

  tearDownAll(() {
    try {
      _dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _calls.clear();
    _analysis = {
      'w': _w,
      'h': _h,
      'fullW': 1000,
      'fullH': 500,
      'kind': 'subject',
      'mask': _maskOf({1, 2}),
      'labels': Uint8List.fromList([
        for (var y = 0; y < _h; y++)
          for (var x = 0; x < _w; x++) _labelAt(x, y),
      ]),
      'lw': _w,
      'lh': _h,
      'subjects': [
        {'id': 1, 'x': 0.0, 'y': 0.0, 'w': 0.5, 'h': 1.0},
        {'id': 2, 'x': 0.75, 'y': 0.0, 'w': 0.25, 'h': 1.0},
      ],
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cutout, (call) async {
          _calls.add(call);
          switch (call.method) {
            case 'analyzePhoto':
              return _analysis;
            case 'photoMask':
              final ids = {...(call.arguments as Map)['ids'] as List};
              return {'w': _w, 'h': _h, 'mask': _maskOf(ids.cast<int>())};
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_cutout, null);
  });

  testWidgets('一進來自動找主體、全部留下；每個主體一個縮圖', (t) async {
    await _open(t);
    expect(_calls.where((c) => c.method == 'analyzePhoto'), hasLength(1));
    expect(_avatars, findsNWidgets(2));
    final p = _painter(t);
    expect(p.raw, isFalse, reason: '分析好了：畫去背後的樣子');
    expect(p.mask, isNotNull);
    expect(p.bg, PhotoCutBg.clear);
  });

  testWidgets('點縮圖、點照片上的主體＝留↔不留；上一步退得回來', (t) async {
    await _open(t);
    // 點主體 2 的縮圖：剩主體 1，跟原生要只有 1 的遮罩
    await t.tap(_avatars.at(1));
    await _settle(t, 4);
    expect(_photoMaskIds(), [1]);

    // 點照片左半（主體 1）：一個都不留——不必問原生
    final r = _photoRect(t);
    _calls.clear();
    await t.tapAt(Offset(r.left + r.width * 0.25, r.center.dy));
    await _settle(t, 4);
    expect(_calls.where((c) => c.method == 'photoMask'), isEmpty);

    // 一個都沒留：匯出擋下來
    await t.tap(find.text('匯出'));
    await t.pump();
    expect(find.text('還沒有留下任何主體'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));

    // 上一步：主體 1 回來
    await t.tap(find.byIcon(Icons.undo));
    await _settle(t, 4);
    expect(_photoMaskIds(), [1]);
  });

  testWidgets('修邊：一指畫一筆，保留／擦除照選的', (t) async {
    await _open(t);
    await t.tap(find.text('修邊'));
    await t.pump();
    await t.tap(find.text('擦除'));
    await t.pump();
    final r = _photoRect(t);
    final g = await t.startGesture(Offset(r.left + 20, r.center.dy));
    for (var i = 1; i <= 6; i++) {
      await g.moveBy(const Offset(15, 0));
      await t.pump();
    }
    await g.up();
    await t.pump();
    final strokes = _painter(t).strokes as List<CutStroke>;
    expect(strokes, hasLength(1));
    expect(strokes.single.keep, isFalse);
    expect(strokes.single.points.length, greaterThan(3));
    // 座標是照片的 0~1
    expect(strokes.single.points.first.dx, inInclusiveRange(0.0, 0.1));
  });

  testWidgets('背景：透明／模糊／純色換得過去', (t) async {
    await _open(t);
    await t.tap(find.text('背景'));
    await t.pump();
    await t.tap(find.text('模糊'));
    await t.pump();
    expect(_painter(t).bg, PhotoCutBg.blur);
    // 第一顆色點（白）
    await t.tap(find.byType(CutoutSwatch).first);
    await t.pump();
    expect(_painter(t).bg, PhotoCutBg.color);
    expect(_painter(t).color, 0xFFFFFFFF);
    await t.tap(find.text('透明'));
    await t.pump();
    expect(_painter(t).bg, PhotoCutBg.clear);
  });

  testWidgets('找不到（通道回 null）：提示、照片照樣看得到、不炸', (t) async {
    _analysis = null;
    await _open(t);
    expect(find.text('這張照片沒辦法自動去背'), findsOneWidget);
    expect(_painter(t).raw, isTrue, reason: '沒去背：畫原圖');
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('只認得出人（主體模型還沒好）：提示這次先只去人', (t) async {
    _analysis = {
      ..._analysis!,
      'kind': 'person',
      'labels': null,
      'lw': 0,
      'lh': 0,
      'subjects': [
        {'id': 1, 'x': 0.0, 'y': 0.0, 'w': 0.5, 'h': 1.0},
      ],
      'note': 'MlKitException: Waiting for the subject segmentation module',
    };
    await _open(t);
    expect(find.text('這次先只認得出人，之後再開就能認其他東西'), findsOneWidget);
    expect(_avatars, findsOneWidget);
    await t.pump(const Duration(seconds: 4));
  });

  testWidgets('改過了按返回：問要不要放棄；沒改過直接走', (t) async {
    await _open(t);
    await t.tap(find.byType(BackButton));
    await _settle(t, 3);
    expect(find.text('open'), findsOneWidget, reason: '沒改過：直接回去');

    await t.tap(find.text('open'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await _settle(t, 12);
    await t.tap(_avatars.at(1));
    await _settle(t, 3);
    await t.tap(find.byType(BackButton));
    await t.pump();
    expect(find.text('放棄這次去背？'), findsOneWidget);
  });

  testWidgets('畫圖：透明只留遮罩、純色墊滿、保留／擦除筆畫照畫', (t) async {
    await t.runAsync(() async {
      // 照片 40×20 全紅；遮罩左半
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(
        const Rect.fromLTWH(0, 0, 40, 20),
        Paint()..color = const Color(0xFFFF0000),
      );
      final photo = await rec.endRecording().toImage(40, 20);
      final m = Uint8List(40 * 20);
      for (var y = 0; y < 20; y++) {
        for (var x = 0; x < 20; x++) {
          m[y * 40 + x] = 255;
        }
      }
      final mask = await maskToImage(m, 40, 20);

      Future<ByteData> render({
        PhotoCutBg bg = PhotoCutBg.clear,
        List<CutStroke> strokes = const [],
      }) async {
        final out = await renderCutout(
          w: 40,
          h: 20,
          photo: photo,
          mask: mask,
          strokes: strokes,
          bg: bg,
          color: 0xFF0000FF,
        );
        final d = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        out.dispose();
        return d;
      }

      int a(ByteData d, int x, int y) => d.getUint8((y * 40 + x) * 4 + 3);
      int ch(ByteData d, int x, int y, int k) =>
          d.getUint8((y * 40 + x) * 4 + k);

      final clear = await render();
      expect(a(clear, 5, 10), 255, reason: '遮罩裡：照片');
      expect(ch(clear, 5, 10, 0), 255);
      expect(a(clear, 35, 10), 0, reason: '遮罩外：透明');

      final blue = await render(bg: PhotoCutBg.color);
      expect(
        [ch(blue, 35, 10, 0), ch(blue, 35, 10, 2), a(blue, 35, 10)],
        [0, 255, 255],
      );
      expect(ch(blue, 5, 10, 0), 255, reason: '主體照舊');

      final edited = await render(
        strokes: [
          // 右半畫一筆「保留」：加回照片；左半畫一筆「擦除」：挖掉
          CutStroke(
            keep: true,
            width: 0.5,
            points: const [Offset(0.875, 0.5), Offset(0.876, 0.5)],
          ),
          CutStroke(
            keep: false,
            width: 0.5,
            points: const [Offset(0.125, 0.5), Offset(0.126, 0.5)],
          ),
        ],
      );
      expect(a(edited, 35, 10), greaterThan(200), reason: '保留：加回來');
      expect(a(edited, 5, 10), lessThan(55), reason: '擦除：挖掉');
      expect(a(edited, 15, 10), 255, reason: '筆畫外照舊');

      photo.dispose();
      mask.dispose();
    });
  });
}
