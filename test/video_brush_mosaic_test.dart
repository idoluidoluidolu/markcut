import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/mosaic.dart';
import 'package:markcut/models/timeline.dart';

void main() {
  test('筆刷馬賽克素材：JSON 來回不失真', () {
    final src = MediaSource(
      path: '',
      name: '筆刷馬賽克',
      kind: ClipKind.mosaic,
      duration: 3600,
      mosaicStyle: MosaicStyle(type: 1, strength: 0.7, feather: 0.3),
      mosaicStroke: [0.1, 0.2, 0.4, 0.5, 0.8, 0.6],
      mosaicBrush: 0.22,
    );
    final back = MediaSource.fromJson(src.toJson());
    expect(back.mosaicStroke, src.mosaicStroke);
    expect(back.mosaicBrush, src.mosaicBrush);
    expect(back.mosaicStyle?.type, 1);
    // 舊資料沒有筆畫欄位：讀回來就是一般方形
    final plain = MediaSource.fromJson(
      MediaSource(
        path: '',
        name: '馬賽克',
        kind: ClipKind.mosaic,
        duration: 3600,
        mosaicStyle: MosaicStyle(),
      ).toJson(),
    );
    expect(plain.mosaicStroke, isNull);
  });
}
