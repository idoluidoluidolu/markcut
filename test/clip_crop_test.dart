import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';

void main() {
  group('片段裁切', () {
    test('沒裁過的片段 cropped 是 false，整張框也算沒裁', () {
      final c = TimelineClip(
        id: 1, sourceIndex: 0, trimStart: 0, trimEnd: 5, offset: 0, track: 0,
      );
      expect(c.cropped, isFalse);
      expect(c.cropL, 0);
      expect(c.cropW, 1);
    });

    test('裁過之後 cropped 是 true', () {
      final c = TimelineClip(
        id: 1, sourceIndex: 0, trimStart: 0, trimEnd: 5, offset: 0, track: 0,
        cropL: 0.2, cropT: 0.1, cropW: 0.5, cropH: 0.6,
      );
      expect(c.cropped, isTrue);
    });

    test('裁切框存得進 JSON 也讀得回來', () {
      final c = TimelineClip(
        id: 7, sourceIndex: 2, trimStart: 1, trimEnd: 4, offset: 2, track: 1,
        cropL: 0.25, cropT: 0.125, cropW: 0.5, cropH: 0.75,
      );
      final back = TimelineClip.fromJson(c.toJson());
      expect(back.cropL, closeTo(0.25, 1e-9));
      expect(back.cropT, closeTo(0.125, 1e-9));
      expect(back.cropW, closeTo(0.5, 1e-9));
      expect(back.cropH, closeTo(0.75, 1e-9));
      expect(back.cropped, isTrue);
    });

    test('舊草稿沒有 crop 欄位，讀回來是整張', () {
      final j = {
        'id': 1, 'sourceIndex': 0, 'trimStart': 0, 'trimEnd': 3,
        'offset': 0, 'track': 0,
      };
      final c = TimelineClip.fromJson(j);
      expect(c.cropped, isFalse);
      expect(c.cropW, 1);
      expect(c.cropH, 1);
    });

    test('沒裁的片段不會把 crop 欄位寫進 JSON（草稿不變胖）', () {
      final c = TimelineClip(
        id: 1, sourceIndex: 0, trimStart: 0, trimEnd: 5, offset: 0, track: 0,
      );
      expect(c.toJson().containsKey('crop'), isFalse);
    });

    test('複製片段會連裁切框一起帶走', () {
      final c = TimelineClip(
        id: 3, sourceIndex: 0, trimStart: 0, trimEnd: 5, offset: 0, track: 0,
        cropL: 0.1, cropT: 0.2, cropW: 0.3, cropH: 0.4,
      );
      final d = c.copy();
      expect(d.cropL, closeTo(0.1, 1e-9));
      expect(d.cropH, closeTo(0.4, 1e-9));
    });

    test('裁切不動 scale／px／py：單純的裁切不放大填滿', () {
      final c = TimelineClip(
        id: 1, sourceIndex: 0, trimStart: 0, trimEnd: 5, offset: 0, track: 0,
        cropL: 0.3, cropT: 0.3, cropW: 0.2, cropH: 0.2,
      );
      expect(c.scale, 1.0);
      expect(c.px, 0.5);
      expect(c.py, 0.5);
    });
  });
}
