// 全 App 的比例選項順序（使用者指定：「整個 App 比例排序的地方都第一個
// 數字從小到大排列，比較整齊」）。
//
// 影片／批次的比例視窗與照片編輯都照 video_processor 的 ratioOrder；
// 裁切頁、浮水印工作室各自有一份清單，這裡把三處的順序都釘住——
// 改了其中一處而忘了另一處，就是「同一個 App 兩種順序」。
//
// 工作室多守一件事：順序改了，新範本的預設比例還是 16:9。預設是照
// designAspect 的預設值找最接近的一格，不是寫死第 0 格
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:markcut/screens/crop_screen.dart';
import 'package:markcut/screens/watermark_studio_screen.dart';
import 'package:markcut/services/video_processor.dart';
import 'package:markcut/theme.dart';

/// 由左到右量每個標籤的 x，確認就是這個順序
void expectLeftToRight(WidgetTester t, List<String> labels) {
  final xs = <double>[];
  for (final l in labels) {
    expect(find.text(l), findsOneWidget, reason: '少了「$l」');
    xs.add(t.getCenter(find.text(l)).dx);
  }
  for (var i = 1; i < xs.length; i++) {
    expect(
      xs[i] > xs[i - 1],
      isTrue,
      reason: '順序不對：${labels[i - 1]} 應該在 ${labels[i]} 左邊（量到 $xs）',
    );
  }
}

Future<Uint8List> _fakePhoto() async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawRect(
    const Rect.fromLTWH(0, 0, 90, 120),
    Paint()..color = const Color(0xFF3A5A8C),
  );
  final img = await rec.endRecording().toImage(90, 120);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('影片／批次／照片編輯共用的 ratioOrder：原始最前，其餘首位數字由小到大', () {
    expect(
      [for (final r in ratioOrder) r.label],
      ['原始', '1:1', '3:4', '4:3', '4:5', '9:16', '16:9'],
    );
  });

  testWidgets('裁切頁：自由最前，其餘首位數字由小到大', (t) async {
    final bytes = (await t.runAsync(_fakePhoto))!;
    await t.binding.setSurfaceSize(const Size(390, 780));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        home: CropScreen(bytes: bytes),
      ),
    );
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await t.pump();
    expectLeftToRight(t, const ['自由', '1:1', '3:4', '4:3', '9:16', '16:9']);
  });

  testWidgets('浮水印工作室：首位數字由小到大；新範本預設仍是 16:9', (t) async {
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: buildStudioTheme(),
        home: const WatermarkStudioScreen(),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    expectLeftToRight(t, const ['1:1', '9:16', '16:9']);

    // 選中的那一格字是粗的；新範本要落在 16:9（不是排第一的 1:1）
    FontWeight? weightOf(String label) =>
        t.widget<Text>(find.text(label)).style?.fontWeight;
    expect(weightOf('16:9'), FontWeight.w700, reason: '新範本預設要是 16:9');
    expect(weightOf('1:1'), isNot(FontWeight.w700), reason: '順序改了，預設跟著跑到第一格');
    expect(
      find.byWidgetPredicate(
        (w) => w is AspectRatio && (w.aspectRatio - 16 / 9).abs() < 1e-6,
      ),
      findsWidgets,
      reason: '示意畫面沒有用 16:9 畫',
    );
    expect(t.takeException(), isNull);
  });
}
