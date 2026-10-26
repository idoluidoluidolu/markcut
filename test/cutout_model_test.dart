// 去背的資料模型：片段的開關／背景、素材的遮罩檔都要進草稿與上一步；
// 時間對照（片段的第 t 秒 → 遮罩的第幾秒）三條路（Flutter 預覽、原生
// 合成器、FFmpeg）共用同一套，倒轉檔要換回原檔的秒數
import 'package:flutter_test/flutter_test.dart';
import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/storage_usage.dart';

MediaSource _video({String path = '/v.mp4', String? mask, String? revOf}) =>
    MediaSource(
      path: path,
      name: 'v',
      kind: ClipKind.video,
      duration: 10,
      w: 1920,
      h: 1080,
      cutMask: mask,
      revOf: revOf,
      revStart: revOf == null ? 0 : 2,
      revEnd: revOf == null ? 0 : 6,
    );

TimelineClip _clip({
  double trimStart = 1,
  double trimEnd = 5,
  double offset = 3,
  double speed = 1,
  bool reverse = false,
  ClipCutout? cutout,
}) => TimelineClip(
  id: 7,
  sourceIndex: 0,
  trimStart: trimStart,
  trimEnd: trimEnd,
  offset: offset,
  track: 0,
  speed: speed,
  reverse: reverse,
  cutout: cutout,
);

void main() {
  test('片段的去背進草稿、讀得回來；沒開不寫鍵', () {
    final c = _clip(cutout: ClipCutout(bg: CutoutBg.color, color: 0xFF00B140));
    final j = c.toJson();
    expect(j['cut'], {'bg': 1, 'color': 0xFF00B140});
    final back = TimelineClip.fromJson(j);
    expect(back.cutout, ClipCutout(bg: CutoutBg.color, color: 0xFF00B140));
    expect(_clip().toJson().containsKey('cut'), isFalse);
    expect(TimelineClip.fromJson(_clip().toJson()).cutout, isNull);
    // 透明背景不記顏色（讀回來是預設白）
    expect(_clip(cutout: ClipCutout()).toJson()['cut'], {'bg': 0});
  });

  test('切割的後半段、複製都帶著去背（而且是各自一份）', () {
    final c = _clip(cutout: ClipCutout(bg: CutoutBg.blur));
    final tail = c.tailClone(
      id: 8,
      sourceIndex: 0,
      trimStart: 3,
      trimEnd: 5,
      offset: 5,
    );
    expect(tail.cutout, ClipCutout(bg: CutoutBg.blur));
    expect(identical(tail.cutout, c.cutout), isFalse);
    expect(c.copy().cutout, ClipCutout(bg: CutoutBg.blur));
  });

  test('素材的遮罩檔進草稿；換實體檔（快速匯出換工作檔）也帶著', () {
    final s = _video(mask: '/w/cut1.mcmk');
    expect(s.toJson()['cutMask'], '/w/cut1.mcmk');
    expect(MediaSource.fromJson(s.toJson()).cutMask, '/w/cut1.mcmk');
    expect(s.withPath('/w/work.mp4').cutMask, '/w/cut1.mcmk');
    expect(_video().toJson().containsKey('cutMask'), isFalse);
    expect(MediaSource.fromJson({'path': 'a', 'cutMask': ''}).cutMask, isNull);
  });

  test('草稿夾算容量、刪草稿清檔案：遮罩檔算在草稿用到的檔案裡', () {
    final refs = draftRefsOf({
      'sources': [_video(mask: '/w/cut1.mcmk').toJson()],
    });
    expect(refs, contains('/w/cut1.mcmk'));
  });

  test('時間對照：片段的第 t 秒 → 遮罩秒數（修剪、位移、變速）', () {
    final s = _video();
    final c = _clip(trimStart: 1, offset: 3, speed: 2);
    expect(cutoutMaskTime(c, s, 3), 1);
    expect(cutoutMaskTime(c, s, 4), 3);
    final m = cutoutMaskMap(c, s);
    expect((m.m0, m.dir), (1.0, 1));
  });

  test('倒轉檔：第 u 秒＝原檔的 revEnd − u 秒（沿用原檔的遮罩）', () {
    final s = _video(path: '/rev.mp4', revOf: '/v.mp4');
    final c = _clip(trimStart: 0.5, trimEnd: 4, offset: 0);
    // 片段開頭＝倒轉檔 0.5 秒＝原檔 6 − 0.5 秒
    expect(cutoutMaskTime(c, s, 0), 5.5);
    expect(cutoutMaskTime(c, s, 1), 4.5);
    final m = cutoutMaskMap(c, s);
    expect((m.m0, m.dir), (5.5, -1));
    // 簡易倒轉（沒做成倒轉檔、reverse 旗標）走 sourceTimeAt 自己的倒著走
    final simple = _clip(trimStart: 1, trimEnd: 5, offset: 0, reverse: true);
    expect(cutoutMaskTime(simple, _video(), 1), 4);
  });

  test('原生要的欄位：開了、遮罩也好了才送；倒轉檔方向是 −1', () {
    final c = _clip(cutout: ClipCutout(bg: CutoutBg.color, color: 0xFFFFFFFF));
    expect(cutoutPayload(c, _video()), isNull, reason: '遮罩還沒算好');
    expect(cutoutPayload(_clip(), _video(mask: '/m')), isNull, reason: '沒開');
    expect(cutoutPayload(c, _video(mask: '/m')), {
      'mask': '/m',
      'm0': 1.0,
      'dir': 1,
      'bg': 1,
      'color': 0xFFFFFFFF,
    });
    final rev = cutoutPayload(c, _video(mask: '/m', revOf: '/v.mp4'))!;
    expect(rev['dir'], -1);
    expect(rev['m0'], 5.0);
    expect(cutoutActive(c, _video(mask: '/m')), isTrue);
    expect(cutoutActive(c, _video(mask: '')), isFalse);
  });

  test('壞資料：背景編號超出範圍夾回、不是表就當沒開', () {
    expect(ClipCutout.fromJson({'bg': 99})!.bg, CutoutBg.values.last);
    expect(ClipCutout.fromJson('x'), isNull);
    expect(ClipCutout.fromJson(null), isNull);
  });
}
