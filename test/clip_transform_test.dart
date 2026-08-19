import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';

TimelineClip _clip({double opacity = 1.0, double rotation = 0}) => TimelineClip(
  id: 1,
  sourceIndex: 0,
  trimStart: 0,
  trimEnd: 5,
  offset: 0,
  track: 0,
  opacity: opacity,
  rotation: rotation,
);

void main() {
  group('片段的旋轉與透明度', () {
    test('預設是不透明、沒旋轉', () {
      final c = _clip();
      expect(c.opacity, 1.0);
      expect(c.rotation, 0);
      expect(c.faded, isFalse);
      expect(c.rotated, isFalse);
    });

    test('浮點誤差不算「有調過」', () {
      expect(_clip(opacity: 0.9999).faded, isFalse);
      expect(_clip(rotation: 0.01).rotated, isFalse);
      expect(_clip(opacity: 0.8).faded, isTrue);
      expect(_clip(rotation: -15).rotated, isTrue);
    });

    test('存得進 JSON 也讀得回來', () {
      final back = TimelineClip.fromJson(
        _clip(opacity: 0.35, rotation: -42.5).toJson(),
      );
      expect(back.opacity, closeTo(0.35, 1e-9));
      expect(back.rotation, closeTo(-42.5, 1e-9));
    });

    test('沒調過就不寫進 JSON（草稿不變胖）', () {
      final j = _clip().toJson();
      expect(j.containsKey('opacity'), isFalse);
      expect(j.containsKey('rotation'), isFalse);
    });

    test('舊草稿沒有這兩個欄位，讀回來是預設值', () {
      final c = TimelineClip.fromJson({
        'id': 1,
        'sourceIndex': 0,
        'trimStart': 0,
        'trimEnd': 3,
        'offset': 0,
        'track': 0,
      });
      expect(c.opacity, 1.0);
      expect(c.rotation, 0);
    });

    test('複製會帶走旋轉與透明度', () {
      final d = _clip(opacity: 0.5, rotation: 90).copy();
      expect(d.opacity, closeTo(0.5, 1e-9));
      expect(d.rotation, closeTo(90, 1e-9));
    });
  });
}
