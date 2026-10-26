// 去背遮罩檔（.mcmk）：原生端（Swift／Kotlin）寫、Dart 端讀（Android 預覽、
// FFmpeg 匯出）。這裡驗 Dart 那份讀寫器與格式本身：
//   1. 寫進去的每一格讀得回來，時間查表取「不晚於這一刻的最後一格」
//   2. 壞檔（截斷、魔術字不對、索引超出檔尾）一律回 null，不丟例外
//   3. 匯出用的遮罩串流：每一格輸出畫面一張、縮到上限、對齊偶數
//   4. 給 Flutter 畫的 RGBA：alpha＝遮罩
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/services/cutout_mask.dart';

Uint8List _frame(int w, int h, int Function(int x, int y) f) {
  final b = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      b[y * w + x] = f(x, y);
    }
  }
  return b;
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('markcut_mcmk_');
  });
  tearDown(() => dir.delete(recursive: true));

  String path(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test('寫進去的每一格讀得回來，時間查表取不晚於那一刻的最後一格', () {
    final p = path('a.mcmk');
    final w = CutoutMaskWriter(p, 4, 2);
    for (var i = 0; i < 3; i++) {
      w.add(i / 30, _frame(4, 2, (x, y) => i * 50 + y * 10 + x));
    }
    w.close();

    final m = CutoutMaskFile.openSync(p)!;
    addTearDown(m.close);
    expect(m.width, 4);
    expect(m.height, 2);
    expect(m.length, 3);
    expect(m.indexAt(-1), 0, reason: '比第一格早：用第一格');
    expect(m.indexAt(0), 0);
    expect(m.indexAt(1 / 30), 1, reason: '剛好落在格子上不能掉到前一格');
    expect(m.indexAt(1.5 / 30), 1);
    expect(m.indexAt(99), 2);
    expect(m.frameAt(1.5 / 30), _frame(4, 2, (x, y) => 50 + y * 10 + x));
    expect(m.frame(2), _frame(4, 2, (x, y) => 100 + y * 10 + x));
    expect(m.frame(3), isNull);
    expect(m.frame(-1), isNull);
  });

  test('檔頭照格式：MCMK、版本 1、小端序的寬高格數與索引位置', () {
    final p = path('h.mcmk');
    final w = CutoutMaskWriter(p, 300, 2);
    w.add(0, Uint8List(600));
    w.add(0.5, Uint8List(600));
    w.close();
    final b = ByteData.sublistView(File(p).readAsBytesSync());
    expect(String.fromCharCodes(b.buffer.asUint8List(0, 4)), 'MCMK');
    expect(b.getUint16(4, Endian.little), 1);
    expect(b.getUint16(8, Endian.little), 300);
    expect(b.getUint16(10, Endian.little), 2);
    expect(b.getUint32(12, Endian.little), 2);
    final idx = b.getUint64(16, Endian.little);
    expect(idx + 2 * 24, b.lengthInBytes, reason: '索引在檔尾');
    expect(b.getFloat64(idx.toInt() + 24, Endian.little), 0.5);
  });

  test('壞檔回 null：不存在、截斷、魔術字不對、索引超出檔尾', () {
    expect(CutoutMaskFile.openSync(path('none.mcmk')), isNull);
    final p = path('b.mcmk');
    final w = CutoutMaskWriter(p, 4, 4)..add(0, Uint8List(16));
    w.close();
    final good = File(p).readAsBytesSync();

    File(p).writeAsBytesSync(good.sublist(0, 10));
    expect(CutoutMaskFile.openSync(p), isNull, reason: '截斷');

    final bad = Uint8List.fromList(good)..[0] = 0x58;
    File(p).writeAsBytesSync(bad);
    expect(CutoutMaskFile.openSync(p), isNull, reason: '魔術字');

    final cut = Uint8List.fromList(good.sublist(0, good.length - 5));
    File(p).writeAsBytesSync(cut);
    expect(CutoutMaskFile.openSync(p), isNull, reason: '索引被截掉');

    // 寫到一半（還沒寫索引、檔頭還是零）＝寫入中被關掉
    final half = CutoutMaskWriter(path('c.mcmk'), 4, 4)..add(0, Uint8List(16));
    expect(CutoutMaskFile.openSync(path('c.mcmk')), isNull);
    half.close();
    final done = CutoutMaskFile.openSync(path('c.mcmk'));
    expect(done, isNotNull);
    done!.close();
  });

  test('匯出的遮罩串流：每個時間一格、依序；縮到上限、寬高對齊偶數', () {
    final p = path('s.mcmk');
    final w = CutoutMaskWriter(p, 640, 361);
    w.add(0, Uint8List(640 * 361)); // 全背景
    w.add(1, Uint8List(640 * 361)..fillRange(0, 640 * 361, 255)); // 全人
    w.close();
    final out = path('s.gray');
    final r = writeCutoutRawSync(
      maskPath: p,
      outPath: out,
      times: [0, 0.5, 1, 2],
      maxSide: 320,
    )!;
    // 640×361 縮到長邊 320 → 320×180.5 → 對齊偶數
    expect(r, (320, 182));
    final bytes = File(out).readAsBytesSync();
    expect(bytes.length, 4 * 320 * 182);
    int at(int frame) => bytes[frame * 320 * 182 + 1000];
    expect([at(0), at(1), at(2), at(3)], [0, 0, 255, 255]);
  });

  test('遮罩檔讀不到：串流回 null（呼叫端改成整張匯出）', () {
    expect(
      writeCutoutRawSync(
        maskPath: path('none.mcmk'),
        outPath: path('x.gray'),
        times: [0],
      ),
      isNull,
    );
  });

  test('遮罩縮放：同尺寸原樣、縮小是內插（邊界是中間值）', () {
    final src = _frame(4, 2, (x, _) => x < 2 ? 0 : 200);
    expect(identical(resizeMask(src, 4, 2, 4, 2), src), isTrue);
    final half = resizeMask(src, 4, 2, 2, 1);
    expect(half.length, 2);
    expect(half[0], lessThan(half[1]));
    final up = resizeMask(src, 4, 2, 8, 4);
    expect(up[0], 0);
    expect(up[7], 200);
    expect(up[3], inExclusiveRange(0, 200), reason: '交界是漸層');
  });

  test('給 Flutter 畫的 RGBA：alpha＝遮罩、顏色不超過 alpha（預乘也合法）', () {
    final rgba = maskToRgba(Uint8List.fromList([0, 128, 255]));
    expect(rgba, [0, 0, 0, 0, 128, 128, 128, 128, 255, 255, 255, 255]);
  });
}
