// HDR 照片（圖片素材）在 HDR 合成裡的契約。
//
// 使用者回報：HDR 專案裡加進來的照片「有點暗、顏色跟原圖有點差」。
// 根因之一：烘進合成的圖片只解 8-bit 基底（增益圖丟掉），相簿卻是用
// HDR 顯示的。原生端（AppDelegate.swift 的 MCStillLoader）現在在 HDR
// 合成裡用 expandToHDR 展開；Dart 這邊要釘住的是：
//   1. HDR 合成先探測、HDR 照片的 still 帶 'hdr' 旗標（原生端不再讀檔頭）
//   2. HDR 合成裡的 HDR 照片一律烘進合成（Flutter 畫的是 8-bit 基底，
//      跟展開後的那份不一樣亮，不能在兩條路之間切來切去）
//   3. SDR 合成一個位元都不變：不探測、不帶旗標、烘的規則照舊
//   4. 探測快取：同一張只探一次；探不到不進快取（下次再探）
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:markcut/models/timeline.dart';
import 'package:markcut/services/comp_player.dart';

void main() {
  const ch = MethodChannel('markcut/comp');
  late List<Map<Object?, Object?>> sent;
  late List<String> probed;

  setUp(() {
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    sent = [];
    probed = [];
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'build':
          sent.add(call.arguments as Map<Object?, Object?>);
          return <String, dynamic>{'textureId': 1, 'duration': 8.0};
      }
      return null;
    });
    CompPlayer.debugClearHdrStills();
    // 假探測：路徑含 hdr＝HDR 照片、含 unknown＝探不到、其餘 SDR
    CompPlayer.debugHdrProbe = (p) async {
      probed.add(p);
      if (p.contains('unknown')) return null;
      return p.contains('hdr');
    };
  });

  tearDown(() {
    CompPlayer.debugHdrProbe = null;
    CompPlayer.debugClearHdrStills();
    final b = TestWidgetsFlutterBinding.ensureInitialized();
    b.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
  });

  /// HDR 影片 0~5 秒（給 workHdrPath＝HDR 判定免探測，不碰檔案系統）
  TimelineModel base() {
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
        trimEnd: 5,
        offset: 0,
        track: 0,
      ),
    );
    return tl;
  }

  int addImage(
    TimelineModel tl,
    String path, {
    double at = 1,
    double len = 3,
    int track = 5,
    bool gif = false,
  }) {
    tl.sources.add(
      MediaSource(
        path: path,
        name: path,
        kind: ClipKind.image,
        duration: 3600,
        isGif: gif,
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

  group('bakedImageIds', () {
    test('SDR 合成：HDR 照片壓在影片之上照舊不烘（Flutter 畫、可即時拖）', () {
      final tl = base();
      addImage(tl, '/hdr.heic'); // track 5＝高於所有影片軌
      CompPlayer.debugSetHdrStill('/hdr.heic', true);
      expect(CompPlayer.bakedImageIds(tl), isEmpty);
      expect(CompPlayer.bakedImageIds(tl, hdrOut: false), isEmpty);
    });

    test('HDR 合成：HDR 照片壓在影片之上也要烘（兩份不一樣亮，不能切）', () {
      final tl = base();
      final id = addImage(tl, '/hdr.heic');
      CompPlayer.debugSetHdrStill('/hdr.heic', true);
      expect(CompPlayer.bakedImageIds(tl, hdrOut: true), {id});
    });

    test('HDR 合成：SDR 照片、沒探過的、GIF 都不受影響', () {
      final tl = base();
      addImage(tl, '/sdr.jpg');
      addImage(tl, '/never.png');
      addImage(tl, '/anim.gif', gif: true);
      CompPlayer.debugSetHdrStill('/sdr.jpg', false);
      // GIF 就算探測說是 HDR（不可能，但釘住規則）也不強制烘
      CompPlayer.debugSetHdrStill('/anim.gif', true);
      expect(CompPlayer.bakedImageIds(tl, hdrOut: true), isEmpty);
    });

    test('HDR 合成：隱藏軌上的 HDR 照片不烘（隱藏軌整條不進合成）', () {
      final tl = base();
      addImage(tl, '/hdr.heic', track: 3);
      CompPlayer.debugSetHdrStill('/hdr.heic', true);
      expect(
        CompPlayer.bakedImageIds(tl, hdrOut: true, hiddenTracks: {3}),
        isEmpty,
      );
    });

    test('原本的規則一字不動：墊在影片下層／被浮水印蓋到照舊烘', () {
      final tl = base();
      final under = addImage(tl, '/sdr.jpg', track: 0);
      final overWm = addImage(tl, '/sdr2.jpg', track: 5);
      expect(CompPlayer.bakedImageIds(tl, hdrOut: true), {under});
      expect(
        CompPlayer.bakedImageIds(tl, hdrOut: true, wmStart: 0, wmEnd: 5),
        {under, overWm},
      );
    });
  });

  group('build payload', () {
    test('hdrOut：先探測，HDR 照片烘進 stills 且帶 hdr 旗標', () async {
      final tl = base();
      addImage(tl, '/hdr.heic'); // 壓在影片之上：只因為是 HDR 照片才烘
      expect(await CompPlayer.build(tl, hdrOut: true), isNotNull);
      expect(probed, contains('/hdr.heic'));
      expect(sent.single['hdrOut'], isTrue);
      final stills = sent.single['stills'] as List<Object?>;
      expect(stills, hasLength(1));
      final st = stills.single as Map<Object?, Object?>;
      expect(st['path'], '/hdr.heic');
      expect(st['hdr'], isTrue);
      // 組建完成後呼叫端算的集合要跟 payload 同一份（同一個快取）
      expect(CompPlayer.isHdrStill('/hdr.heic'), isTrue);
      expect(CompPlayer.bakedImageIds(tl, hdrOut: true), {tl.clips.last.id});
    });

    test('hdrOut：SDR 照片烘進去時不帶 hdr 鍵（原生端照舊 8-bit 基底）', () async {
      final tl = base();
      addImage(tl, '/sdr.jpg', track: 0); // 墊在影片下層＝本來就烘
      expect(await CompPlayer.build(tl, hdrOut: true), isNotNull);
      expect(probed, contains('/sdr.jpg'));
      final st = (sent.single['stills'] as List<Object?>).single
          as Map<Object?, Object?>;
      expect(st.containsKey('hdr'), isFalse);
    });

    test('SDR 合成：不探測、不帶 hdr 鍵、HDR 照片不因此烘', () async {
      final tl = base();
      addImage(tl, '/hdr.heic'); // 壓在影片之上
      addImage(tl, '/hdr2.heic', track: 0); // 墊底＝本來就烘
      CompPlayer.debugSetHdrStill('/hdr.heic', true);
      CompPlayer.debugSetHdrStill('/hdr2.heic', true);
      expect(await CompPlayer.build(tl), isNotNull);
      expect(probed, isEmpty);
      final stills = sent.single['stills'] as List<Object?>;
      expect(stills, hasLength(1));
      final st = stills.single as Map<Object?, Object?>;
      expect(st['path'], '/hdr2.heic');
      expect(st.containsKey('hdr'), isFalse);
    });

    test('探測快取：同一張只探一次；探不到不進快取、下次再探', () async {
      final tl = base();
      addImage(tl, '/hdr.heic');
      addImage(tl, '/unknown.png');
      addImage(tl, '/anim.gif', gif: true);
      await CompPlayer.probeHdrStills(tl);
      await CompPlayer.probeHdrStills(tl);
      expect(probed.where((p) => p == '/hdr.heic'), hasLength(1));
      expect(probed.where((p) => p == '/unknown.png'), hasLength(2));
      expect(probed, isNot(contains('/anim.gif')));
      expect(CompPlayer.isHdrStill('/hdr.heic'), isTrue);
      expect(CompPlayer.isHdrStill('/unknown.png'), isFalse);
    });
  });
}
