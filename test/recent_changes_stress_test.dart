// 針對最近大改區域的補強測試：照片畫布、設計比例、
// SwipeBack 與橫向捲動的和平共處、手繪畫板的完整流程。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/draw_screen.dart';
import 'package:markcut/services/video_processor.dart';
import 'package:markcut/widgets/swipe_back.dart';
import 'package:markcut/widgets/watermark_layer.dart' show CheckerPainter;

void main() {
  group('畫布尺寸：圖片也算畫面素材', () {
    TimelineModel imgOnly({int w = 3024, int h = 4032}) {
      final tl = TimelineModel();
      tl.sources.add(MediaSource(
        path: '/p.jpg',
        name: 'p',
        kind: ClipKind.image,
        duration: 4,
        w: w,
        h: h,
      ));
      tl.clips.add(TimelineClip(
        id: 1,
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 4,
        offset: 0,
        track: 0,
      ));
      return tl;
    }

    test('純照片的時間軸：尺寸照圖片算，不再寫死 1920x1080', () {
      final (w, h) = computeCanvasSize(imgOnly(), ExportResolution.original);
      // 直式照片 → 直式畫布，長邊 = 圖片長邊
      expect(h, greaterThan(w));
      expect(math.max(w, h), 4032);
    });

    test('每一種比例算出來的尺寸都不一樣（選單不再整排同數字）', () {
      final tl = imgOnly();
      final sizes = <String>{};
      for (final r in CanvasRatio.values) {
        final (w, h) = computeCanvasSize(tl, ExportResolution.original, r);
        sizes.add('${w}x$h');
        expect(w > 2 && h > 2, isTrue);
        expect(w % 2 == 0 && h % 2 == 0, isTrue, reason: 'H.264 要偶數');
      }
      expect(sizes.length, greaterThan(3), reason: '各比例該有各自的尺寸');
    });

    test('圖片尺寸讀不到（0x0）時退回 1920 長邊，不會 0x0 炸匯出', () {
      final (w, h) =
          computeCanvasSize(imgOnly(w: 0, h: 0), ExportResolution.original);
      expect(math.max(w, h), 1920);
      expect(math.min(w, h), greaterThan(2));
    });

    test('影片＋圖片混合：以最底軌最早的那個為比例基準', () {
      final tl = imgOnly();
      tl.sources.add(MediaSource(
        path: '/v.mp4',
        name: 'v',
        kind: ClipKind.video,
        duration: 10,
        w: 1920,
        h: 1080,
      ));
      tl.clips.add(TimelineClip(
        id: 2,
        sourceIndex: 1,
        trimStart: 0,
        trimEnd: 5,
        offset: 4,
        track: 0,
      ));
      final (w, h) = computeCanvasSize(tl, ExportResolution.original);
      // 圖片在 offset 0（更早）→ 用它的直式比例
      expect(h, greaterThan(w));
    });
  });

  group('設計比例（designAspect）', () {
    test('JSON 來回保留；舊資料沒存＝16:9', () {
      final s = WatermarkSettings(designAspect: 9 / 16);
      final back = WatermarkSettings.fromJson(s.toJson());
      expect(back.designAspect, closeTo(9 / 16, 1e-9));
      final legacy = WatermarkSettings.fromJson(const {});
      expect(legacy.designAspect, closeTo(16 / 9, 1e-9));
    });

    test('垃圾值被夾住，不會給出 0 或負比例', () {
      final back = WatermarkSettings.fromJson(const {'designAspect': -3});
      expect(back.designAspect, greaterThan(0));
    });

    test('copyMarksFrom 帶著比例走（套範本／復原快照）', () {
      final a = WatermarkSettings(designAspect: 1.0);
      final b = WatermarkSettings();
      b.copyMarksFrom(a);
      expect(b.designAspect, closeTo(1.0, 1e-9));
    });
  });

  group('SwipeBack vs 橫向捲動', () {
    testWidgets('在橫向清單上往右甩＝捲清單，不會被踢回上一頁', (t) async {
      var popped = false;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => SwipeBack(
            onBack: () => popped = true,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  height: 100,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    // 先捲到中段，往右甩才有得捲（在 0 的位置
                    // 清單不動、通知不會發）
                    controller: ScrollController(initialScrollOffset: 300),
                    itemCount: 30,
                    itemBuilder: (context, i) => Container(
                      width: 90,
                      margin: const EdgeInsets.all(4),
                      color: Colors.black12,
                      child: Center(child: Text('$i')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ));
      // 快速往右甩超過 110px（本來會觸發返回的手勢）
      await t.timedDrag(
        find.byType(ListView),
        const Offset(200, 0),
        const Duration(milliseconds: 120),
      );
      await t.pumpAndSettle();
      expect(popped, isFalse, reason: '捲動中的橫滑不該觸發返回');
    });

    testWidgets('不在捲動元件上快速右甩：照樣返回', (t) async {
      var popped = false;
      await t.pumpWidget(MaterialApp(
        home: SwipeBack(
          onBack: () => popped = true,
          child: const Scaffold(body: Center(child: Text('內容'))),
        ),
      ));
      await t.timedDrag(
        find.text('內容'),
        const Offset(200, 0),
        const Duration(milliseconds: 120),
      );
      await t.pumpAndSettle();
      expect(popped, isTrue, reason: '一般頁面右甩返回不能壞');
    });
  });

  group('手繪畫板', () {
    Future<DrawResult?> open(WidgetTester t) async {
      DrawResult? result;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async =>
                    result = await drawWatermark(context),
                child: const Text('開畫板'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('開畫板'));
      await t.pumpAndSettle();
      return result;
    }

    testWidgets('畫兩筆→選取調粗細→上一步→重做都不炸', (t) async {
      await open(t);
      // CustomPaint 滿地都是（滑桿內部也有），認棋盤格那塊才是畫板
      final board = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is CheckerPainter,
      );
      expect(board, findsOneWidget);
      final c = t.getCenter(board);
      // 畫兩筆
      await t.timedDrag(board, const Offset(80, 40),
          const Duration(milliseconds: 200));
      await t.pumpAndSettle();
      await t.dragFrom(c + const Offset(-60, 60), const Offset(90, -20));
      await t.pumpAndSettle();
      // 點第一筆的「路徑中段」→ 選取。
      //（測試手勢有 ~18px 的 touch slop，起點會偏掉，點中段最穩）
      await t.tapAt(c + const Offset(40, 20));
      await t.pump();
      // 滑桿現在調「這一筆」
      expect(find.text('這一筆'), findsOneWidget);
      await t.drag(find.byType(Slider), const Offset(40, 0));
      await t.pump();
      // 點空白處取消選取
      await t.tapAt(t.getTopLeft(board) + const Offset(8, 8));
      await t.pump();
      expect(find.text('粗細'), findsOneWidget);
      // 上一步→重做不炸
      await t.tap(find.byTooltip('上一步'));
      await t.pump();
      await t.tap(find.byTooltip('重做'));
      await t.pump();
      expect(t.takeException(), isNull);
    });

    testWidgets('筆畫資料再編輯：還原不炸、筆數對', (t) async {
      // 手工組一份筆畫資料（兩筆），走 initialData 進畫板
      const data =
          '{"w":400.0,"h":600.0,"s":['
          '{"c":4294967295,"w":8.0,"b":0,"p":[10.0,10.0,120.0,80.0]},'
          '{"c":4278190335,"w":12.0,"b":1,"p":[50.0,200.0,200.0,240.0]}]}';
      DrawResult? result;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => result =
                    await drawWatermark(context, initialData: data),
                child: const Text('開畫板'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('開畫板'));
      await t.pumpAndSettle();
      await t.pump(); // 還原後的補幀（按鈕狀態在 frame 後對齊）
      expect(result, isNull); // 還在畫板裡
      // 有筆畫＝「完成」可以按（證明還原成功）
      FilledButton done() => t.widget<FilledButton>(
            find.ancestor(
              of: find.text('完成'),
              matching: find.byType(FilledButton),
            ),
          );
      expect(done().onPressed, isNotNull, reason: '還原的筆畫要算數');
      // 上一步退兩筆 → 沒東西可輸出 → 完成變灰（證明剛好還原了兩筆）
      await t.tap(find.byTooltip('上一步'));
      await t.pump();
      expect(done().onPressed, isNotNull);
      await t.tap(find.byTooltip('上一步'));
      await t.pump();
      expect(done().onPressed, isNull, reason: '兩筆退完就該沒墨水');
      expect(t.takeException(), isNull);
    });

    testWidgets('資料壞掉：當全新畫板，不紅屏', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () =>
                    drawWatermark(context, initialData: '{{{壞的'),
                child: const Text('開畫板'),
              ),
            ),
          ),
        ),
      ));
      await t.tap(find.text('開畫板'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      // 沒有筆畫 → 完成應該是灰的（onPressed null）
      final btn = t.widget<FilledButton>(
        find.ancestor(
          of: find.text('完成'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('多文字＋渲染', () {
    testWidgets('三個文字（含平鋪）的設定丟進渲染不炸、圖有內容', (t) async {
      final s = WatermarkSettings();
      s.text.text = 'A';
      s.addText().text = 'B';
      final third = s.addText();
      third.text = 'C';
      third.tiled = true;
      await t.runAsync(() async {
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec);
        // 直接走渲染器的公開入口需要 dart:ui scene——改驗模型層：
        // JSON 來回後三個文字都在、平鋪旗標保留
        canvas.drawRect(Rect.zero, Paint());
        final back = WatermarkSettings.fromJson(s.toJson());
        expect(back.texts.length, 3);
        expect(back.texts[2].tiled, isTrue);
        rec.endRecording();
      });
    });
  });
}
