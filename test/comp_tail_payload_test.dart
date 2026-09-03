// 合成播放器 payload 的「時間軸尾巴」契約。
//
// 影片播完之後時間軸還有東西（圖片/文字/貼圖/配樂）時，以前整組退回
// 逐片段材質播放器——那條路是 8-bit BGRA，根本顯示不了 HDR，就是
// 「加入圖片素材後為啥整個 HDR 效果都不見了」。現在改成把合成本身
// 補長到時間軸終點（CompPlayer.padTo → 原生端 build 的
// timelineDuration → 畫面軌鋪到那裡）。
//
// 這裡測的兩件事只在 payload 裡看得到（whyNot/padTo 那些純邏輯測試
// 看不到），而漏掉的症狀是「預覽的尾巴一片空、匯出卻有圖」：
//   1. timelineDuration 有送、而且就是 padTo 的值
//   2. 跨過影片結尾的圖片層不再被夾掉（start/end 完整送出去）
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/comp_player.dart';

void main() {
  const ch = MethodChannel('markcut/comp');
  late List<Map<Object?, Object?>> sent;

  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    sent = [];
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          sent.add(call.arguments as Map<Object?, Object?>);
          // 組起來了：欄位照原生端的回傳格式（textureId/duration 必要）
          return <String, dynamic>{'textureId': 1, 'duration': 8.0};
      }
      return null;
    });
  });

  tearDown(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
  });

  /// 影片 0~5 秒（給 workPath＝不會去探測 HDR，測試不碰檔案系統）
  TimelineModel base() {
    final tl = TimelineModel();
    tl.sources.add(
      MediaSource(
        path: '/a.mp4',
        name: 'a',
        kind: ClipKind.video,
        duration: 100,
        workPath: '/a.work.mp4',
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: 5,
        offset: 0,
        track: 0,
      ),
    );
    return tl;
  }

  void addImage(TimelineModel tl, {required double at, required double len}) {
    tl.sources.add(
      MediaSource(
        path: '/p.png',
        name: 'p',
        kind: ClipKind.image,
        duration: 3600,
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: len,
        offset: at,
        // 跟影片同軌（不高於最高影片軌）＝烘進合成，不是 Flutter 畫的
        track: 0,
      ),
    );
  }

  test('圖片跨過影片結尾：送 timelineDuration，圖片層不再被夾掉', () async {
    final tl = base(); // 影片 0~5 秒
    addImage(tl, at: 4, len: 4); // 圖片 4~8 秒
    expect(await CompPlayer.build(tl), isNotNull);
    expect(sent, hasLength(1));

    // 原生端照這個值把畫面軌鋪到 8 秒；沒有它，播放時鐘走到 5 秒就停住
    expect(sent.single['timelineDuration'], CompPlayer.padTo(tl));
    expect(sent.single['timelineDuration'], 8.0);

    final stills = sent.single['stills'] as List<Object?>;
    expect(stills, hasLength(1), reason: '跨過片尾的圖片還是要烘進合成');
    final st = stills.single as Map<Object?, Object?>;
    expect(st['start'], 4.0);
    // 以前這裡被夾成 5.0（合成只到影片結尾）＝尾巴那 3 秒看不到圖，
    // 匯出卻有——預覽跟成品對不上的經典形狀
    expect(st['end'], 8.0);
  });

  test('沒有尾巴的專案：timelineDuration 送 0（原生端一格都不補）', () async {
    final tl = base(); // 影片 0~5 秒
    addImage(tl, at: 1, len: 3); // 圖片 1~4 秒，整段在影片裡
    expect(await CompPlayer.build(tl), isNotNull);

    expect(sent.single['timelineDuration'], 0.0);
    final st = (sent.single['stills'] as List<Object?>).single
        as Map<Object?, Object?>;
    expect(st['start'], 1.0);
    expect(st['end'], 4.0);
  });

  test('尾巴在隱藏軌上：不補（隱藏軌整條不進合成）', () async {
    final tl = base(); // 影片 0~5 秒
    addImage(tl, at: 6, len: 3); // 圖片 6~9 秒
    tl.clips.last.track = 2;
    expect(await CompPlayer.build(tl, hiddenTracks: {2}), isNotNull);

    expect(sent.single['timelineDuration'], 0.0);
    expect(sent.single['stills'], isEmpty);
  });
}
