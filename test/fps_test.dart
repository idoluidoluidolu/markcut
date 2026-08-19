import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/video_processor.dart';

void main() {
  group('匯出張數', () {
    test('沒指定就跟著素材', () {
      expect(outputFps(24, 1920, 1080), 24);
      expect(outputFps(59.94, 1920, 1080), closeTo(59.94, 0.01));
    });

    test('讀不到素材幀率時退回 30', () {
      expect(outputFps(0, 1920, 1080), 30);
      expect(outputFps(1000, 1920, 1080), 30);
    });

    test('指定的張數會被套用', () {
      expect(outputFps(60, 1920, 1080, want: 30), 30);
      expect(outputFps(60, 1920, 1080, want: 24), 24);
    });

    test('指定的張數不會超過素材本身有的', () {
      // 30fps 的素材選 60：寫成 60 只是每格存兩次，檔案兩倍畫面一樣
      expect(outputFps(30, 1920, 1080, want: 60), 30);
    });

    test('4K 以上仍然壓在 60 以內', () {
      expect(outputFps(120, 3840, 2160), 60);
      expect(outputFps(120, 3840, 2160, want: 120), 60);
    });

    test('素材讀不到幀率時，指定的張數仍以 30 為天花板', () {
      expect(outputFps(0, 1920, 1080, want: 60), 30);
      expect(outputFps(0, 1920, 1080, want: 24), 24);
    });

    test('選項清單第一個是自動', () {
      expect(kFpsChoices.first, 0);
      expect(kFpsChoices.contains(30), isTrue);
    });

    test('自動的說明會帶出素材的張數', () {
      expect(fpsNote(0, 59.94), contains('60'));
      expect(fpsNote(0, 0), '跟素材一樣');
    });
  });
}
