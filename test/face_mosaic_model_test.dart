// 找臉馬賽克在資料層的幾件事：
//   1. 頭像那一格（mosaicFaceAt）跟著草稿存、切割複製一份獨立的
//   2. 頭像從那一格裁正方形：臉框外留一點、不跑出畫面
//   3. 一鍵補洞不搬找臉的片段（它跟影片內容對時，挪了就碼錯地方）
//   4. 片段的 scale 乘在送出去的臉框大小上
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/widgets/face_avatar.dart';

MediaSource _face({List<double>? at}) => MediaSource(
  path: '',
  name: '臉 1',
  kind: ClipKind.mosaic,
  duration: 3600,
  mosaicStyle: MosaicStyle(strength: 0.85),
  mosaicPath: [0.0, 0.3, 0.3, 0.1, 0.15, 2.0, 0.6, 0.3, 0.1, 0.15],
  mosaicOval: true,
  mosaicFace: true,
  mosaicFaceAt: at,
);

void main() {
  test('頭像那一格：JSON 來回不失真，切割複製的是獨立一份', () {
    final s = _face(at: [0, 1.5, 0.25, 0.25, 0.1, 0.15]);
    final back = MediaSource.fromJson(s.toJson());
    expect(back.mosaicFaceAt, [0, 1.5, 0.25, 0.25, 0.1, 0.15]);
    expect(back.mosaicFace, isTrue);

    final dup = s.dupStyle();
    dup.mosaicFaceAt![1] = 9;
    expect(s.mosaicFaceAt![1], 1.5, reason: '改切出來的那半不能動到原本的');

    // 欄位不完整（舊版、壞掉的草稿）：當作沒有，不炸
    final bad = s.toJson()..['mzFaceAt'] = [0, 1];
    expect(MediaSource.fromJson(bad).mosaicFaceAt, isNull);
    expect(MediaSource.fromJson(_face().toJson()).mosaicFaceAt, isNull);
  });

  test('頭像裁切：臉框放大 1.5 倍的正方形，靠邊時整塊往內推', () {
    // 1000×500 的一格，臉框 100×100 像素、中心 (450, 200)
    expect(
      faceAvatarCrop(const Rect.fromLTWH(0.4, 0.3, 0.1, 0.2), 1000, 500),
      rectMoreOrLessEquals(const Rect.fromLTWH(375, 125, 150, 150)),
    );
    // 貼著右上角：不跑出畫面
    expect(
      faceAvatarCrop(const Rect.fromLTWH(0.95, 0.0, 0.05, 0.1), 1000, 500),
      rectMoreOrLessEquals(const Rect.fromLTWH(925, 0, 75, 75)),
    );
    // 臉框比畫面還大：最多裁到短邊那麼大
    final huge = faceAvatarCrop(const Rect.fromLTWH(0, 0, 1, 1), 1000, 500);
    expect(huge.width, 500);
    expect(huge.height, 500);
    expect(huge.left, greaterThanOrEqualTo(0));
    expect(huge.right, lessThanOrEqualTo(1000));
  });

  test('一鍵補洞：找臉的片段原地不動，一般片段照樣接上', () {
    final tl = TimelineModel();
    tl.sources
      ..add(_face())
      ..add(
        MediaSource(path: '', name: '字', kind: ClipKind.text, duration: 3600),
      );
    tl.clips
      ..add(
        TimelineClip(
          id: 1,
          sourceIndex: 1,
          trimStart: 0,
          trimEnd: 1,
          offset: 0,
          track: 1,
        ),
      )
      ..add(
        TimelineClip(
          id: 2,
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 2,
          offset: 1.5,
          track: 1,
        ),
      )
      ..add(
        TimelineClip(
          id: 3,
          sourceIndex: 1,
          trimStart: 0,
          trimEnd: 1,
          offset: 5,
          track: 1,
        ),
      );
    tl.closeGaps(track: 1);
    final byId = {for (final c in tl.clips) c.id: c};
    expect(byId[2]!.offset, 1.5, reason: '找臉的片段跟著影片對時，不能挪');
    expect(byId[3]!.offset, 3.5, reason: '後面的接在找臉片段的結尾');
  });

  test('送出去的軌跡：時間換成時間軸秒數，臉框乘片段的 scale', () {
    final c = TimelineClip(
      id: 1,
      sourceIndex: 0,
      trimStart: 0.5,
      trimEnd: 2,
      offset: 3,
      track: 1,
      scale: 1.5,
    );
    final keys = _face().mosaicPath!;
    final out = c.mosaicPathOnTimeline(keys, sp: 2);
    expect(out[0], closeTo((3 + (0 - 0.5)) / 2, 1e-9));
    expect(out[5], closeTo((3 + (2 - 0.5)) / 2, 1e-9));
    expect(out[1], 0.3, reason: '中心不變');
    expect(out[3], closeTo(0.15, 1e-9));
    expect(out[4], closeTo(0.225, 1e-9));
    expect(keys[3], 0.1, reason: '原本那份不能被改到');
  });
}
