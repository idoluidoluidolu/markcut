import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/mosaic.dart';
import 'package:markcut/models/watermark_settings.dart';
import 'package:markcut/services/watermark_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('筆刷馬賽克：JSON 來回不失真', () {
    final m = PhotoMosaic(
      stroke: [0.1, 0.5, 0.4, 0.5, 0.8, 0.6],
      brush: 0.2,
      style: MosaicStyle(type: 2, color: 0xFF112233),
    );
    final back = PhotoMosaic.fromJson(m.toJson());
    expect(back.isStroke, isTrue);
    expect(back.stroke, m.stroke);
    expect(back.brush, m.brush);
    expect(back.style.type, 2);
    // 舊資料沒有 stroke 欄位：讀回來就是方形
    expect(PhotoMosaic.fromJson(PhotoMosaic().toJson()).isStroke, isFalse);
  });

  test('筆刷馬賽克：匯出畫在筆畫上、不畫到外面', () async {
    // 一張 200x200 純紅照片
    final rec = ui.PictureRecorder();
    ui.Canvas(rec).drawRect(
      const ui.Rect.fromLTWH(0, 0, 200, 200),
      ui.Paint()..color = const ui.Color(0xFFFF0000),
    );
    final img = await rec.endRecording().toImage(200, 200);
    final photoPng = Uint8List.view(
      (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer,
    );

    // 橫向一筆純黑遮蓋，粗 20%（40px），走畫面中線
    final out = await WatermarkRenderer.renderPhotoComposite(
      photoPng,
      WatermarkSettings(
        text: TextMark(enabled: false),
        logo: LogoMark(enabled: false),
      ),
      mosaics: [
        PhotoMosaic(
          stroke: [0.2, 0.5, 0.8, 0.5],
          brush: 0.2,
          style: MosaicStyle(type: 2, color: 0xFF000000),
        ),
      ],
    );
    final codec = await ui.instantiateImageCodec(out);
    final f = await codec.getNextFrame();
    final px = (await f.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    int r(int x, int y) => px.getUint8((y * 200 + x) * 4);
    // 筆畫中心（100,100）被遮成黑
    expect(r(100, 100), lessThan(30), reason: '筆畫上要打到碼');
    // 角落離筆畫很遠，保持紅
    expect(r(10, 10), greaterThan(200), reason: '筆畫外不能被動到');
    expect(r(190, 190), greaterThan(200));
  });
}
