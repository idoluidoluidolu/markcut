// 兩指旋轉吸附（RotationSnap）的手感契約：門檻、遲滯、只在換刻度時震。
//
// 背景：使用者回報「浮水印文字放大縮小時螢幕會震動」。兩指縮放時手指
// 連線的角度自然會抖個三五度，舊的吸附是每一格重判一次：抖進 3~4 度
// 就黏上 0 度並震一下，抖出 4 度就脫離（文字順手轉歪 4~6 度），再抖回來
// 又黏上又震——一次純縮放震十幾下、文字在 0 度跟 5 度之間跳。
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/services/rotation_snap.dart';

void main() {
  late List<String> haptics;

  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    haptics = [];
    b.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add('${call.arguments}');
      }
      return null;
    });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('純縮放的抖動（隨機 ±6 度、30 格）：角度一動不動、一次都不震', () {
    final s = RotationSnap()..arm(0);
    final rnd = math.Random(7);
    for (var i = 0; i < 30; i++) {
      expect(s.delta(rnd.nextDouble() * 12 - 6), 0);
    }
    expect(haptics, isEmpty);
  });

  test('抖在門檻兩側（3.5／5 度交替、30 格）：以前每兩格震一次，現在零次', () {
    final s = RotationSnap()..arm(0);
    for (var i = 0; i < 30; i++) {
      expect(s.delta(i.isEven ? 3.5 : 5.0), 0, reason: '第 $i 格');
    }
    expect(haptics, isEmpty);
    // 已經轉過門檻、黏在 0 度上，但從沒離開過起手的刻度：輔助線不畫
    //（以前抖進 3~4 度就閃一條「0°」的線出來、抖出去又消失）
    expect(s.engaged, isTrue);
    expect(s.guide, isNull);
  });

  test('沒轉過門檻（3 度內）什麼都不做，輔助線也不畫', () {
    final s = RotationSnap()..arm(0);
    expect(s.delta(2.9), 0);
    expect(s.delta(-3), 0);
    expect(s.engaged, isFalse);
    expect(s.guide, isNull);
    expect(haptics, isEmpty);
  });

  test('真的轉過去（0→90 度、每格 3 度）：每跨一個 15 度刻度震一次、最後吸在 90', () {
    final s = RotationSnap()..arm(0);
    final out = <double>[];
    for (var i = 1; i <= 30; i++) {
      out.add(s.delta(i * 3.0));
    }
    expect(haptics.length, 6, reason: '15、30、45、60、75、90 各一次');
    expect(out.last, 90);
    expect(out[3], 15, reason: '轉到 12 度就黏上 15');
    expect(s.guide, 90);
  });

  test('遲滯：黏住後 8 度內都留在刻度上，超過才脫離；再黏回同一個刻度不震', () {
    final s = RotationSnap()..arm(0);
    expect(s.delta(20), 20, reason: '離 15 有 5 度、離 30 有 10 度：自由');
    expect(s.guide, isNull);
    expect(s.delta(17), 15, reason: '2 度內黏上 15');
    expect(haptics.length, 1);
    expect(s.guide, 15, reason: '真的轉到 15 了：輔助線畫出來');
    expect(s.delta(22), 15, reason: '離 15 七度：還黏著');
    expect(s.guide, 15, reason: '黏著的期間線穩定亮著，不閃');
    expect(s.delta(24), 24, reason: '離 15 九度：脫離');
    expect(s.guide, isNull);
    expect(s.delta(18), 15, reason: '回來又黏上 15');
    expect(haptics.length, 1, reason: '同一個刻度不再震');
  });

  test('起手就精準坐在 0 度：轉過門檻先黏著 0（不震），轉夠了才走', () {
    final s = RotationSnap()..arm(0);
    expect(s.delta(4), 0);
    expect(s.delta(7.9), 0);
    expect(haptics, isEmpty);
    expect(s.delta(8.1), 8.1);
    expect(haptics, isEmpty);
  });

  test('起手在刻度旁邊（12 度）：被磁鐵拉上 15 要震一次，之後抖動不再震', () {
    final s = RotationSnap()..arm(12);
    expect(s.delta(3.5), 3, reason: '12+3.5 → 黏 15 → 修正量 3');
    expect(haptics.length, 1);
    expect(s.guide, 15, reason: '角度被磁鐵動過了：輔助線要畫');
    expect(s.delta(6), 3);
    expect(s.delta(2), 3);
    expect(haptics.length, 1);
  });

  test('起手離刻度遠（9 度）：黏上 15 震一次', () {
    final s = RotationSnap()..arm(9);
    expect(s.delta(3.5), 6, reason: '9+3.5=12.5 → 黏 15 → 修正量 6');
    expect(haptics.length, 1);
  });

  test('兩個目標同一個修正量：文字 0 度、圖片 10 度一起轉，相對角度不變', () {
    final s = RotationSnap()..arm(0);
    for (var i = 1; i <= 20; i++) {
      final d = s.delta(i * 2.0);
      final text = RotationSnap.wrapDeg(0 + d);
      final logo = RotationSnap.wrapDeg(10 + d);
      expect(RotationSnap.wrapDeg(logo - text), closeTo(10, 1e-9));
    }
    expect(haptics.length, 2, reason: '15、30');
  });

  test('±180 接縫：170 轉 8 度黏 180；轉到 -170 脫離；再黏 -165 是新刻度', () {
    final s = RotationSnap()..arm(170);
    expect(s.delta(8), 10, reason: '178 → 黏 180');
    expect(haptics.length, 1);
    expect(s.delta(14), 10, reason: '184＝-176，離 180 四度：還黏著');
    expect(s.delta(20), 20, reason: '-170：離 180 十度脫離、離 -165 五度自由');
    expect(haptics.length, 1);
    expect(s.delta(24), 25, reason: '-166 → 黏 -165 → 修正量 wrap(-165-170)');
    expect(haptics.length, 2);
  });

  test('180 與 -180 是同一個刻度：從 180 出去再黏回 -180 不震', () {
    final s = RotationSnap()..arm(180);
    expect(s.delta(5), 0);
    expect(s.delta(10), 10, reason: '-170：脫離');
    expect(s.delta(3.5), 0, reason: '-176.5 → 黏 -180＝起手那個刻度');
    expect(haptics, isEmpty);
  });

  test('放手後重新起手：上一手的狀態不帶到這一手', () {
    final s = RotationSnap()..arm(0);
    expect(s.delta(17), 15);
    expect(haptics.length, 1);
    s.end();
    expect(s.guide, isNull);
    expect(s.engaged, isFalse);
    s.arm(15);
    expect(s.delta(2), 0, reason: '門檻重新算');
    expect(s.delta(4), 0, reason: '精準坐在 15 上：黏著、不震');
    expect(haptics.length, 1);
  });
}
