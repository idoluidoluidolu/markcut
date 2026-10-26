// 預覽上 Flutter 畫的去背（Android 的播放器圖層、拖曳快取幀）：
//   1. 照時間挑格：播到哪一格就用那一格的遮罩（解好才換，中間不閃回整張）
//   2. 透明背景只留遮罩那一塊；純色墊滿自己的框；模糊墊同一個畫面糊過的
//   3. 遮罩檔讀不到：照舊整張畫，不要整層不見
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/cutout.dart';
import 'package:markcut/services/cutout_mask.dart';
import 'package:markcut/widgets/cutout_layer.dart';

void main() {
  late Directory dir;
  late String mask;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('markcut_clayer_');
    mask = '${dir.path}${Platform.pathSeparator}m.mcmk';
    // 4×2：第 0 秒人在左半、第 1 秒換到右半
    final w = CutoutMaskWriter(mask, 4, 2);
    w.add(0, Uint8List.fromList([255, 255, 0, 0, 255, 255, 0, 0]));
    w.add(1, Uint8List.fromList([0, 0, 255, 255, 0, 0, 255, 255]));
    w.close();
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final key = GlobalKey();

  Future<void> pump(
    WidgetTester t, {
    required double time,
    ClipCutout? cut,
    String? path,
  }) async {
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 40,
              height: 20,
              child: CutoutLayer(
                maskPath: path ?? mask,
                time: time,
                cut: cut ?? ClipCutout(),
                blurSource: const ColoredBox(color: Color(0xFF00FF00)),
                child: const ColoredBox(color: Color(0xFFFF0000)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 解遮罩是真的非同步
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 6; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
  }

  Future<List<int>> pixel(WidgetTester t, int x, int y) async {
    final out = await t.runAsync(() async {
      final b =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage();
      final d = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final i = (y * img.width + x) * 4;
      final px = [
        d.getUint8(i),
        d.getUint8(i + 1),
        d.getUint8(i + 2),
        d.getUint8(i + 3),
      ];
      img.dispose();
      return px;
    });
    return out!;
  }

  testWidgets('照時間挑格：第 0 秒人在左、第 1 秒換到右', (t) async {
    await pump(t, time: 0.2);
    await settle(t);
    expect(find.byType(ShaderMask), findsOneWidget);
    expect((await pixel(t, 5, 10))[3], 255, reason: '左半是人');
    expect((await pixel(t, 35, 10))[3], 0, reason: '右半透明');

    await pump(t, time: 1.4);
    await settle(t);
    expect((await pixel(t, 5, 10))[3], 0);
    expect((await pixel(t, 35, 10))[3], 255);
  });

  testWidgets('純色墊滿自己的框；模糊墊同一個畫面（這裡是綠的）', (t) async {
    await pump(
      t,
      time: 0,
      cut: ClipCutout(bg: CutoutBg.color, color: 0xFF0000FF),
    );
    await settle(t);
    expect(await pixel(t, 35, 10), [0, 0, 255, 255], reason: '背景那一側是藍的');
    expect(await pixel(t, 5, 10), [255, 0, 0, 255], reason: '人照舊');

    await pump(t, time: 0, cut: ClipCutout(bg: CutoutBg.blur));
    await settle(t);
    final bg = await pixel(t, 35, 10);
    expect(bg[1], greaterThan(200), reason: '模糊背景是同一個畫面（綠）');
    expect(bg[3], 255);
  });

  testWidgets('遮罩檔讀不到：照舊整張畫', (t) async {
    await pump(t, time: 0, path: '${dir.path}/none.mcmk');
    await settle(t);
    expect(find.byType(ShaderMask), findsNothing);
    expect((await pixel(t, 35, 10))[3], 255);
  });
}
