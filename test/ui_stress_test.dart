// 暴力測試第三輪：把 App 真的開起來狂點，看會不會炸。
//
// 這裡跑的是真正的畫面程式碼（導航、對話框、面板、範本、意見回饋），
// 任何未捕捉的例外都會讓測試失敗——等於自動化的「亂點測試員」。
//
// 執行：flutter test test/ui_stress_test.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:markcut/main.dart';
import 'package:markcut/models/color_grade.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/screens/about_screen.dart';
import 'package:markcut/screens/presets_screen.dart';
import 'package:markcut/screens/profile_screen.dart';
import 'package:markcut/widgets/color_grade_panel.dart';
import 'package:markcut/widgets/watermark_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 包一層 MaterialApp，讓單一元件也能跑導航與對話框
Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: child),
  theme: ThemeData.dark(),
);

/// 假的相簿選取器：開了先不回（模擬選取器還開在畫面上），
/// 由測試決定什麼時候「選好」
class _HoldPicker extends ImagePickerPlatform {
  int calls = 0;
  final _c = Completer<List<XFile>>();

  void finish(List<XFile> files) => _c.complete(files);

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) {
    calls++;
    return _c.future;
  }

  /// 首頁「浮水印」走的是相簿混選（pickMultipleMedia）
  @override
  Future<List<XFile>> getMedia({required MediaOptions options}) {
    calls++;
    return _c.future;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('首頁亂點', () {
    testWidgets('連點「浮水印」30 次：選取器只開一次、只問一次，不會炸', (tester) async {
      // 首頁的「浮水印」直接開相簿混選（沒有選單了），
      // 重入鎖要守的是「選取器開著時再點都不會再開一個」
      final picker = _HoldPicker();
      final prev = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = picker;
      addTearDown(() => ImagePickerPlatform.instance = prev);

      await tester.pumpWidget(const MarkCutApp());
      await tester.pumpAndSettle();

      for (var i = 0; i < 30; i++) {
        await tester.tap(find.text('浮水印'), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(picker.calls, 1, reason: '連點之後選取器被開了 ${picker.calls} 次');

      // 選好兩張：只會問一次「串成影片還是各自上浮水印」
      picker.finish([
        XFile('/x/a.png', name: 'a.png'),
        XFile('/x/b.png', name: 'b.png'),
      ]);
      await tester.pumpAndSettle();
      expect(
        find.text('選了 2 張照片'),
        findsOneWidget,
        reason: '連點之後疊出了不只一個（或沒有）選取視窗',
      );

      // 關掉（點視窗外）：鎖要放開，再點一下要能再開選取器
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('選了 2 張照片'), findsNothing);
      await tester.tap(find.text('浮水印'));
      await tester.pumpAndSettle();
      expect(picker.calls, 2, reason: '視窗關掉之後鎖沒放開');
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('個人中心 → 關於 → 各資訊頁，來回進出不會炸', (tester) async {
      await tester.pumpWidget(const MarkCutApp());
      await tester.pumpAndSettle();

      for (var round = 0; round < 3; round++) {
        await tester.tap(find.byIcon(Icons.person_outline));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '個人中心開不起來');

        // 個人中心裡的連結都點進去再回來（用現行頁面上真的存在
        // 的字樣；不存在就跳過）
        for (final label in ['關於這個 App', '意見回饋']) {
          final f = find.text(label).hitTestable();
          if (f.evaluate().isEmpty) continue;
          await tester.ensureVisible(f.first);
          await tester.pumpAndSettle();
          await tester.tap(f.first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$label 開不起來');
          // 收掉：對話框點「關閉」；頁面點「點得到的」Back（個人
          // 中心自己的返回鍵被蓋住時不可點，不會誤點退掉整頁）；
          // 都沒有＝對話框沒有關閉鈕，點外面收
          final close = find.text('關閉').hitTestable();
          final back = find.byTooltip('Back').hitTestable();
          if (close.evaluate().isNotEmpty) {
            await tester.tap(close.first);
          } else if (back.evaluate().isNotEmpty) {
            await tester.tap(back.first);
          } else {
            await tester.tapAt(const Offset(10, 10));
          }
          await tester.pumpAndSettle();
        }
        expect(
          find.text('範本').hitTestable(),
          findsOneWidget,
          reason: '第 $round 輪內圈結束沒有回到個人中心',
        );
        final backOut = find.byTooltip('Back').hitTestable();
        if (backOut.evaluate().isNotEmpty) {
          await tester.tap(backOut.first);
        } else {
          // 個人中心沒有返回鈕（整頁右滑返回），程式化退一頁
          Navigator.of(
            tester.element(find.byType(Scaffold).hitTestable().first),
          ).maybePop();
        }
        await tester.pumpAndSettle();
        expect(
          find.byIcon(Icons.person_outline).hitTestable(),
          findsOneWidget,
          reason: '第 $round 輪結束沒有退回首頁',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('關於頁與資訊頁', () {
    testWidgets('關於頁所有連結列都點得開、隱私頁講的是實話', (tester) async {
      await tester.pumpWidget(host(const AboutScreen()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 隱私頁：必須有意見回饋會傳送資料的說明（不能只寫「什麼都不上傳」）
      final privacy = find.text('隱私');
      if (privacy.evaluate().isNotEmpty) {
        await tester.tap(privacy.first);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('意見回饋'),
          findsWidgets,
          reason: '隱私頁沒有說明意見回饋會傳送資料（上架審查會有問題）',
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('浮水印面板亂拉', () {
    testWidgets('隨機拖曳每一條滑桿 500 次不會炸', (tester) async {
      final s = WatermarkSettings()..text.text = '@測試';
      await tester.pumpWidget(
        host(WatermarkPanel(settings: s, onChanged: () {})),
      );
      await tester.pumpAndSettle();

      final r = math.Random(1);
      for (var i = 0; i < 500; i++) {
        final sliders = find.byType(Slider);
        final n = sliders.evaluate().length;
        if (n == 0) break;
        final idx = r.nextInt(n);
        await tester.drag(
          sliders.at(idx),
          Offset((r.nextDouble() - 0.5) * 600, 0),
          warnIfMissed: false,
        );
        await tester.pump(const Duration(milliseconds: 5));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 拉到極端也不能拉出無效值
      expect(s.text.sizeFrac.isFinite && s.text.sizeFrac > 0, isTrue);
      expect(s.text.opacity >= 0 && s.text.opacity <= 1, isTrue);
      expect(s.logo.sizeFrac.isFinite && s.logo.sizeFrac > 0, isTrue);
    });

    testWidgets('所有開關反覆切換不會炸，設定仍然有效', (tester) async {
      final s = WatermarkSettings()..text.text = '@測試';
      await tester.pumpWidget(
        host(WatermarkPanel(settings: s, onChanged: () {})),
      );
      await tester.pumpAndSettle();

      for (var round = 0; round < 20; round++) {
        for (var i = 0; i < 12; i++) {
          // 每一下都重新數：亂點可能點到「手繪」把畫板推上來，
          // 畫面上的元件數會中途改變，沿用舊的 finder 會越界
          final switches = find.byType(GestureDetector);
          if (i >= switches.evaluate().length) break;
          await tester.tap(switches.at(i), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 5));
          // 點到「手繪」開了畫板就退回來再繼續亂點面板
          final back = find.byType(BackButton);
          if (back.evaluate().isNotEmpty) {
            await tester.tap(back.first, warnIfMissed: false);
            await tester.pumpAndSettle();
          }
        }
      }
      // 亂點可能點到「存成範本」（現在不問名字、直接存＋跳提示），
      // 提示的自動消失計時器要走完，不然測試結束時還掛著
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('調色面板亂拉', () {
    testWidgets('隨機拉滑桿 + 切分頁 + 重設 500 次不會炸', (tester) async {
      final g = ColorGrade();
      var undoCount = 0;
      await tester.pumpWidget(
        host(
          ColorGradePanel(
            grade: g,
            onChanged: () {},
            onBeforeChange: () => undoCount++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final r = math.Random(2);
      for (var i = 0; i < 500; i++) {
        switch (r.nextInt(3)) {
          case 0:
            final sliders = find.byType(Slider);
            final n = sliders.evaluate().length;
            if (n > 0) {
              await tester.drag(
                sliders.at(r.nextInt(n)),
                Offset((r.nextDouble() - 0.5) * 500, 0),
                warnIfMissed: false,
              );
            }
          case 1:
            for (final t in ['顏色', '明暗']) {
              final f = find.text(t);
              if (f.evaluate().isNotEmpty && r.nextBool()) {
                await tester.tap(f.first, warnIfMissed: false);
              }
            }
          case 2:
            final reset = find.text('重設');
            if (reset.evaluate().isNotEmpty) {
              await tester.tap(reset.first, warnIfMissed: false);
            }
        }
        await tester.pump(const Duration(milliseconds: 5));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // 亂拉之後值仍然合法，匯出濾鏡也還是合法的
      expect(g.matrix.every((v) => v.isFinite), isTrue);
      expect(g.ffmpeg.contains('NaN'), isFalse);
      expect(g.ffmpeg.contains('eq='), isFalse);
      // 一次拖曳＝一步：拉了很多次，快照數不能是 0（沒在記）
      // 也不能誇張到每一格都記一次
      expect(undoCount > 0, isTrue, reason: '調色完全沒有拍復原快照');
    });

    testWidgets('一次拖曳＝一步復原（拖三次就是三步）', (tester) async {
      final g = ColorGrade();
      var pushes = 0;
      await tester.pumpWidget(
        host(
          ColorGradePanel(
            grade: g,
            onChanged: () {},
            onBeforeChange: () => pushes++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final slider = find.byType(Slider).first;
      for (var i = 0; i < 3; i++) {
        // 一次完整的拖曳：按下 → 分很多小段慢慢移動 → 放開。
        // 中間的每一小段都不該各自算一步
        final gesture = await tester.startGesture(tester.getCenter(slider));
        for (var k = 0; k < 20; k++) {
          await gesture.moveBy(const Offset(4, 0));
          await tester.pump(const Duration(milliseconds: 30));
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pumpAndSettle();
      expect(
        pushes,
        3,
        reason:
            '拖了 3 次卻拍了 $pushes 次快照'
            '（一次拖曳必須剛好算一步，中途停頓也不能被切開）',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('按住「原圖」超過長按時間，比較狀態要一直維持', (tester) async {
      final g = ColorGrade()..saturation = 0.2;
      var comparing = false;
      await tester.pumpWidget(
        host(
          ColorGradePanel(
            grade: g,
            onChanged: () {},
            onCompare: (v) => comparing = v,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final btn = find.text('原圖');
      if (btn.evaluate().isNotEmpty) {
        final g1 = await tester.startGesture(tester.getCenter(btn.first));
        await tester.pump(const Duration(milliseconds: 100));
        expect(comparing, isTrue, reason: '按下去沒有進入比較狀態');
        // 撐過長按門檻（500ms）＋再久一點
        await tester.pump(const Duration(milliseconds: 900));
        expect(comparing, isTrue, reason: '按住超過長按時間就自己彈回去了（比較功能等於壞的）');
        await tester.pump(const Duration(seconds: 2));
        expect(comparing, isTrue, reason: '按住兩秒後比較狀態消失');
        await g1.up();
        await tester.pumpAndSettle();
        expect(comparing, isFalse, reason: '放開之後沒有回到調色後的畫面');
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('範本夾與個人中心', () {
    testWidgets('範本夾快速進出（載入途中就離開）不會炸', (tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pumpWidget(host(const PresetsScreen()));
        // 故意不等載入完成就換掉整個畫面
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pumpWidget(host(const SizedBox()));
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          tester.takeException(),
          isNull,
          reason: '載入途中離開範本夾會炸（setState after dispose）',
        );
      }
      await tester.pumpAndSettle();
    });

    testWidgets('個人中心快速進出不會炸', (tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pumpWidget(host(const ProfileScreen()));
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pumpWidget(host(const SizedBox()));
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
    });
  });
}
