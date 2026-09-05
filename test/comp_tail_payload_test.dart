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
import 'package:markcut/services/diagnostics.dart';

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
    CompPlayer.debugHdrProbe = null;
    CompPlayer.debugClearHdrStills();
    Diag.hlgStillInverseOotf = null;
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

  /// 預設跟影片同軌（不高於最高影片軌）＝烘進合成，不是 Flutter 畫的；
  /// [track] 給更高的軌＝壓在影片之上（只有被浮水印蓋到／HDR 照片才烘）
  int addImage(
    TimelineModel tl, {
    required double at,
    required double len,
    int track = 0,
  }) {
    tl.sources.add(
      MediaSource(
        path: '/p.png',
        name: 'p',
        kind: ClipKind.image,
        duration: 3600,
      ),
    );
    final id = tl.nextId();
    tl.clips.add(
      TimelineClip(
        id: id,
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: len,
        offset: at,
        track: track,
      ),
    );
    return id;
  }

  /// 實機回報 1 的時間軸：HDR 影片 0~[vidEnd] 秒在軌 0（給 workHdrPath
  /// ＝HDR 判定免探測，不碰檔案系統）
  TimelineModel baseHdr({double vidEnd = 1}) {
    final tl = TimelineModel();
    tl.sources.add(
      MediaSource(
        path: '/a.mov',
        name: 'a',
        kind: ClipKind.video,
        duration: 100,
        workPath: '/a.work.mp4',
        workHdrPath: '/a.hlg.mp4',
      ),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: 0,
        trimStart: 0,
        trimEnd: vidEnd,
        offset: 0,
        track: 0,
      ),
    );
    return tl;
  }

  /// 文字素材（尾巴只有文字時合成一樣要補長）
  void addText(TimelineModel tl, {required double at, required double len}) {
    tl.sources.add(
      MediaSource(path: '', name: 'hi', kind: ClipKind.text, duration: 3600),
    );
    tl.clips.add(
      TimelineClip(
        id: tl.nextId(),
        sourceIndex: tl.sources.length - 1,
        trimStart: 0,
        trimEnd: len,
        offset: at,
        track: 3,
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

  // ── 實機回報 1：影片 0~1、圖片 0~4 在更高軌、浮水印 0~4、HDR 合成 ──
  //
  // 圖片壓在影片之上但被浮水印蓋到（HDR 合成的浮水印是烘進去的），
  // 所以它也要烘進合成、Flutter 不畫——原生合成器是唯一畫它的人。
  // 這裡釘住 Dart 端送出去的幾何：圖片整段 0~4 都在 payload 裡、
  // 合成補長到 4 秒、烘的集合跟 payload 同一份
  group('實機 1：影片播完之後的圖片', () {
    setUp(() {
      CompPlayer.debugHdrProbe = (p) async => false; // 一般 SDR PNG
    });

    test('HDR 合成、被浮水印蓋到：圖片 0~4 整段烘進去、補長到 4 秒', () async {
      final tl = baseHdr(); // 影片 0~1
      final img = addImage(tl, at: 0, len: 4, track: 1);
      expect(
        CompPlayer.bakedImageIds(tl, wmStart: 0, wmEnd: 4, hdrOut: true),
        {img},
        reason: '被浮水印蓋到的圖片要烘',
      );
      expect(
        await CompPlayer.build(tl, hdrOut: true, wmStart: 0, wmEnd: 4),
        isNotNull,
      );
      final p = sent.single;
      expect(p['hdrOut'], isTrue);
      expect(p['timelineDuration'], 4.0);
      final stills = p['stills'] as List<Object?>;
      expect(stills, hasLength(1));
      final st = stills.single as Map<Object?, Object?>;
      expect(st['start'], 0.0);
      expect(st['end'], 4.0, reason: '尾巴 1~4 秒也要畫，不能夾到影片結尾');
      expect(st['track'], 1);
      expect(st['hdr'], isFalse);
      // 反 OOTF 沒有使用者開關：預設不送鍵＝原生端照中灰探針自動決定
      //（送 false 反而是「強制關」，會蓋掉自動判定）
      expect(p.containsKey('stillInverseOotf'), isFalse);
    });

    test('HDR 合成、沒有浮水印：壓在影片之上的圖片不烘（Flutter 畫），照樣補長', () async {
      final tl = baseHdr();
      addImage(tl, at: 0, len: 4, track: 1);
      expect(CompPlayer.bakedImageIds(tl, hdrOut: true), isEmpty);
      expect(await CompPlayer.build(tl, hdrOut: true), isNotNull);
      expect(sent.single['stills'], isEmpty);
      // 圖片活得比影片久：時鐘還是要走到 4 秒（尾巴黑底、Flutter 畫圖）
      expect(sent.single['timelineDuration'], 4.0);
    });

    test('反 OOTF 診斷強制值：設了才送、true/false 都送（預覽與匯出同一個旗標）', () async {
      final tl = baseHdr();
      addImage(tl, at: 0, len: 4, track: 0);

      Diag.hlgStillInverseOotf = true;
      expect(await CompPlayer.build(tl, hdrOut: true), isNotNull);
      expect(sent.single['stillInverseOotf'], isTrue);

      sent.clear();
      Diag.hlgStillInverseOotf = false;
      expect(await CompPlayer.build(tl, hdrOut: true), isNotNull);
      expect(sent.single['stillInverseOotf'], isFalse, reason: '強制關也要送出去');

      sent.clear();
      Diag.hlgStillInverseOotf = null;
      expect(await CompPlayer.build(tl, hdrOut: true), isNotNull);
      expect(sent.single.containsKey('stillInverseOotf'), isFalse, reason: 'null＝自動，不送鍵');
    });
  });

  // ── 預覽層要不要把合成材質露出來（CompPlayer.paintsAt）──
  //
  // 實機 1 的真正病灶：原生合成器在尾巴每一格都畫了圖，但預覽層用
  // 「播放頭底下有影片才露」把整層藏掉＝黑畫面，只剩 Flutter 那份壓到
  // 1% 透明度的浮水印隱約可見。這裡釘住新的露／藏規則
  group('paintsAt', () {
    test('尾巴裡烘進去的圖片：露；合成結尾以後：藏', () {
      final tl = baseHdr(); // 影片 0~1
      final img = addImage(tl, at: 0, len: 4, track: 1);
      bool at(double t) => CompPlayer.paintsAt(
        tl,
        t,
        bakedIds: {img},
        compDuration: 4.0,
      );
      expect(at(0.5), isTrue, reason: '影片底下');
      expect(at(1.5), isTrue, reason: '實機 1 的那一格：圖片是原生畫的');
      expect(at(3.9), isTrue);
      expect(at(4.0), isFalse, reason: '合成結尾，材質停在最後一幀');
      expect(at(4.5), isFalse);
    });

    test('畫面上那份合成還是舊的（長度只到影片結尾）：尾巴先藏', () {
      final tl = baseHdr();
      final img = addImage(tl, at: 0, len: 4, track: 1);
      expect(
        CompPlayer.paintsAt(tl, 1.5, bakedIds: {img}, compDuration: 1.0),
        isFalse,
      );
    });

    test('尾巴只有文字（沒烘圖片）：補長那段是定義好的黑底，露', () {
      final tl = baseHdr(); // 影片 0~1
      addText(tl, at: 0, len: 4);
      expect(CompPlayer.padTo(tl), 4.0);
      expect(CompPlayer.paintsAt(tl, 2.0, compDuration: 4.0), isTrue);
      expect(CompPlayer.paintsAt(tl, 4.0, compDuration: 4.0), isFalse);
    });

    test('兩段影片之間的空縫、沒補長也沒烘圖：藏（原本的行為）', () {
      final tl = baseHdr(); // 影片 0~1
      tl.clips.add(
        TimelineClip(
          id: tl.nextId(),
          sourceIndex: 0,
          trimStart: 0,
          trimEnd: 1,
          offset: 3, // 第二段 3~4
          track: 0,
        ),
      );
      expect(CompPlayer.padTo(tl), 0.0);
      expect(CompPlayer.paintsAt(tl, 2.0, compDuration: 4.0), isFalse);
      expect(CompPlayer.paintsAt(tl, 3.5, compDuration: 4.0), isTrue);
    });

    test('烘進去的圖片在隱藏軌：整條不進合成，藏', () {
      final tl = baseHdr();
      final img = addImage(tl, at: 0, len: 4, track: 2);
      expect(
        CompPlayer.paintsAt(
          tl,
          1.5,
          hiddenTracks: {2},
          bakedIds: {img},
          compDuration: 4.0,
        ),
        isFalse,
      );
    });
  });
}
